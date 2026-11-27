#import "SiriBridge.h"
#include <string.h>
#include <dispatch/dispatch.h>
#include <notify.h>
#include <dirent.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <errno.h>
#include <unistd.h>
#include <pthread.h>

// 1.6.26→1.6.30：跨进程通道的第三次尝试。
// 设备实测三条都被堵：
//   ① App 侧 CFMessagePortCreateLocal → 沙盒拒（mach-register）；
//   ② App 侧 CFMessagePortCreateRemote（含 com.apple. 前缀）→ 沙盒拒（mach-lookup）；
//   ③ dylib 里的 CFSTR 常量 isa 未认证 → SIGBUS 黑屏（已改成运行时构造）。
// 于是改走 Unix domain socket：App 在自己容器 Documents 建 sb.sock（沙盒允许），
// SpringBoard 枚举容器目录找到这个 socket 再 connect。socket 是文件系统对象，不走 mach。
#define SBAPP_SOCK_NAME "sb.sock"
#define SBAPP_PORT   "com.apple.SiriBridge.ipc"
#define SBAPP_APP_PORT "com.apple.SiriBridge.app"
#define SBAPP_HELLO  "com.doubao.apphello"

static CFMessagePortRef g_sbPort = NULL;
static int g_helloTok = -1;

static CFStringRef SBPortName(const char *s) {
    return CFStringCreateWithCString(NULL, s, kCFStringEncodingUTF8);
}

static CFDataRef sbPortCallback(CFMessagePortRef local, SInt32 msgid, CFDataRef data, void *info) {
    (void)local; (void)info;
    char cmd[240];
    cmd[0] = 0;
    if (data) {
        CFIndex n = CFDataGetLength(data);
        if (n > (CFIndex)sizeof(cmd) - 1) n = sizeof(cmd) - 1;
        CFDataGetBytes(data, CFRangeMake(0, n), (UInt8 *)cmd);
        cmd[n] = 0;
    }
    SBLogSync("APP ipc in msgid=%d <%s>", (int)msgid, cmd);
    const char *out = "ok";
    return CFDataCreate(NULL, (const UInt8 *)out, (CFIndex)strlen(out));
}

void SBAppIPCBoot(void) {
    if (g_sbPort) return;
    CFStringRef nm = SBPortName(SBAPP_PORT);
    if (!nm) { SBLogSync("APP ipc noname"); return; }
    g_sbPort = CFMessagePortCreateLocal(NULL, nm, sbPortCallback, NULL, NULL);
    CFRelease(nm);
    if (!g_sbPort) {
        SBLogSync("APP ipc local fail");
        return;
    }
    CFRunLoopSourceRef src = CFMessagePortCreateRunLoopSource(NULL, g_sbPort, 0);
    if (!src) { SBLogSync("APP ipc source fail"); return; }
    CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopCommonModes);
    CFRelease(src);
    SBLogSync("APP ipc local ready");
}

// 兜底通道：App 用 notify_post 报到，pid 放在 notify state 里（都传不了长字符串，但足以证明通道活着）。
// 1.6.27 黑屏的元凶是 CFSTR 常量，不是 block —— 本文件前面的 dispatch_after 一直工作，block 可用。
void SBAppHelloWatch(void) {
    if (g_helloTok >= 0) return;
    notify_register_dispatch(SBAPP_HELLO, &g_helloTok, dispatch_get_main_queue(), ^(int token) {
        uint64_t appPid = 0;
        notify_get_state(token, &appPid);
        SBLogSync("APP hello notify pid=%llu", (unsigned long long)appPid);
        SBAppPingAsync("hello");   // 微信一起来就自动探一次 socket，不用等语音
        SBAppFindAsync("搜索");     // 顺带验证“按文字找控件”，只报告不点击
        // 1.6.50：删掉此处 8 秒后自动 SBTapOnce(215,125)。
        // 那是 dispatch_sync 主线程 + ScheduleWithRunLoop 主 runloop 的旧写法，
        // 与 backboardd 互等会触发 watchdog；现在点击统一走 SBHid 的安全路径。
    });
    SBLogSync("APP hello watch tok=%d", g_helloTok);
}

// 在容器目录里找 App 建的 socket。SpringBoard 是系统进程，理论上能读所有容器；
// 这一步同时验证「SpringBoard 能不能看见 App 容器」——看不见的话 socket 这条路也得换。
static int SBFindAppSock(char *out, size_t outLen) {
    DIR *d = opendir("/var/mobile/Containers/Data/Application");
    if (!d) { SBLogSync("APP sock opendir fail errno=%d", errno); return 0; }

    struct dirent *de;
    int found = 0;
    int scanned = 0;
    while ((de = readdir(d))) {
        if (de->d_name[0] == '.') continue;
        scanned++;
        char path[460];
        snprintf(path, sizeof path, "/var/mobile/Containers/Data/Application/%s/Documents/%s",
                 de->d_name, SBAPP_SOCK_NAME);
        struct stat st;
        if (stat(path, &st) == 0 && S_ISSOCK(st.st_mode)) {
            snprintf(out, outLen, "%s", path);
            found = 1;
            break;
        }
    }
    closedir(d);
    SBLogSync("APP sock scan n=%d found=%d", scanned, found);
    return found;
}

// 连上 App 的 socket 发一条命令，同步等一句回复（后台线程里跑，0.6 秒超时）
static int SBAppSockCall(const char *cmd, char *reply, size_t replyLen) {
    if (reply && replyLen) reply[0] = 0;
    char path[460];
    if (!SBFindAppSock(path, sizeof path)) {
        SBLogSync("APP sock none");
        return -1;
    }
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) { SBLogSync("APP sock create errno=%d", errno); return -2; }

    struct sockaddr_un sa;
    memset(&sa, 0, sizeof sa);
    sa.sun_family = AF_UNIX;
    snprintf(sa.sun_path, sizeof sa.sun_path, "%s", path);

    struct timeval tv = { 9, 0 };   // 1.6.73：诊断序列 6 步 × 1.2 秒，要 7 秒以上
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);

    if (connect(fd, (struct sockaddr *)&sa, sizeof sa) < 0) {
        SBLogSync("APP sock connect fail errno=%d", errno);
        close(fd);
        return -3;
    }
    send(fd, cmd, strlen(cmd), 0);
    ssize_t n = recv(fd, reply, replyLen - 1, 0);
    close(fd);
    if (n > 0) {
        reply[n] = 0;
        SBLogSync("APP sock reply <%s>", reply);
        return 0;
    }
    SBLogSync("APP sock no reply n=%ld", (long)n);
    return -4;
}

void SBAppPingAsync(const char *why) {
    const char *w = why ? why : "";
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        char rep[300];
        int rc = SBAppSockCall("ping", rep, sizeof rep);
        SBLogSync("APP ping rc=%d (%s)", rc, w);
    });
}

// 1.6.31：让 App 按文字找控件，只回报位置和类名，不点击。
// 1.6.32：让 App 自己“点”一下按文字找到的控件——先在 App 进程里做无障碍激活，
// 不用跨进程注入触摸，失败也不会影响系统稳定性。
void SBAppTapAsync(const char *kw) {
    const char *k = kw ? kw : "";
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        char cmd[80];
        snprintf(cmd, sizeof cmd, "tap:%s", k);
        char rep[1200];
        int rc = SBAppSockCall(cmd, rep, sizeof rep);
        SBLogSync("APP tap rc=%d kw=<%s>", rc, k);
    });
}

void SBAppFindAsync(const char *kw) {
    const char *k = kw ? kw : "";
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        char cmd[80];
        snprintf(cmd, sizeof cmd, "find:%s", k);
        char rep[1200];
        int rc = SBAppSockCall(cmd, rep, sizeof rep);
        SBLogSync("APP find rc=%d kw=<%s>", rc, k);
    });
}

// 1.6.69：一条完整动作命令（可以是 seq: 多步）下发到 App 并执行。
// 与上面两个函数的区别只有一个：命令原样传，不做前缀拼接。
void SBAppActAsync(const char *cmd) {
    const char *c = cmd ? cmd : "";
    if (!*c) return;
    // 1.6.69：异步执行前必须复制一份 —— 调用者的那条 C 字符串在函数返回后就失效了
    char *copy = strdup(c);
    if (!copy) return;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        char rep[1600];
        int rc = SBAppSockCall(copy, rep, sizeof rep);
        SBLogSync("APP act rc=%d cmd=<%s> rep=<%s>", rc, copy, rep);
        free(copy);
    });
}

// 1.6.69：同步调用，调用方自己承担阻塞（只能在后台线程用）。
// 返回值 0 = App 应答了；-4 = 超时没人应答（微信在后台被挂起时就是这个）。
int SBAppActSync(const char *cmd, char *reply, size_t replyLen) {
    return SBAppSockCall(cmd ? cmd : "", reply, replyLen);
}

// 1.6.84：调试/联调通道（临时）。SpringBoard 里起一个线程轮询命令文件，
// 这样不必每次对着 Siri 说话就能驱动 App 侧执行器 —— "AI 接管触摸"的联调全靠它。
//   in : /var/mobile/Library/SiriBridge/in.cmd   一行一条（主机侧写入，写后自动删）
//   out: /var/mobile/Library/SiriBridge/out.txt  每次执行覆盖写（绕过单条 768 字节截断）
#define SB_DEV_IN  "/var/mobile/Library/SiriBridge/in.cmd"
#define SB_DEV_OUT "/var/mobile/Library/SiriBridge/out.txt"

static void sbDevOut(const char *s) {
    FILE *f = fopen(SB_DEV_OUT, "w");
    if (!f) return;
    fwrite(s, 1, strlen(s), f);
    fclose(f);
}

static void *sbDevCmdThread(void *arg) {
    (void)arg;
    for (;;) {
        usleep(700000);
        FILE *f = fopen(SB_DEV_IN, "r");
        if (!f) continue;
        char cmd[220];
        size_t n = fread(cmd, 1, sizeof(cmd) - 1, f);
        fclose(f);
        if (n == 0) { remove(SB_DEV_IN); continue; }
        cmd[n] = 0;
        while (n > 0 && (cmd[n - 1] == '\n' || cmd[n - 1] == '\r' || cmd[n - 1] == ' ')) cmd[--n] = 0;
        remove(SB_DEV_IN);
        if (!n) continue;

        SBLogSync("DEV cmd=<%s>", cmd);
        char rep[1600];
        rep[0] = 0;
        int rc = SBAppActSync("ping", rep, sizeof rep);
        if (rc != 0) {
            // 微信不在前台时 socket 挂着没人应答，先拉起来再等它醒
            SBLogSync("DEV wake app rc=%d", rc);
            SBOpenSchemeURL("weixin://");
            for (int i = 0; i < 8; i++) {
                sleep(2);
                rep[0] = 0;
                rc = SBAppActSync("ping", rep, sizeof rep);
                if (rc == 0) break;
            }
        }
        rep[0] = 0;
        rc = SBAppActSync(cmd, rep, sizeof rep);
        char buf[2200];
        snprintf(buf, sizeof buf, "rc=%d\n%s\n", rc, rep);
        sbDevOut(buf);
        SBLogSync("DEV done rc=%d", rc);
    }
    return NULL;
}

void SBFsCmdBoot(void) {
    pthread_t th;
    if (pthread_create(&th, NULL, sbDevCmdThread, NULL) == 0) pthread_detach(th);
    else SBLogSync("DEV thread fail");
}

