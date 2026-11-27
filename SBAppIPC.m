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

int SBDoAct(const char *instruction, char *out, size_t outLen);

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
        if (strncmp(cmd, "act", 3) == 0) {
            // act:<自然语言指令> —— 走完整的 AI 决策链路（不靠 Siri 也能联调）
            const char *ins = cmd + 3;
            if (*ins == ':' || *ins == ' ') ins++;
            char res[1800];
            res[0] = 0;
            int arc = SBDoAct(ins, res, sizeof res);
            char buf[2000];
            snprintf(buf, sizeof buf, "rc=%d\n%s\n", arc, res);
            sbDevOut(buf);
            continue;
        }
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

// ===== 1.6.85：AI 接管动作（快照 → 模型决策 → 执行 → 回环） =====
// 设计取舍：模型**永不出坐标**，只出「点哪个词/第几个 tab/往哪滑」。
// 坐标由这里按刚取到的快照自己算 —— 快照与执行之间没有时间差，模型也不会算错像素。

typedef struct {
    char tag[8];
    char txt[140];
    double x, y, w, h;
} SBEl;

static BOOL sbElParse(const char *line, size_t len, SBEl *e) {
    memset(e, 0, sizeof *e);
    const char *p = line, *end = line + len;
    while (p < end && *p == ' ') p++;
    while (p < end && *p >= '0' && *p <= '9') p++;          // 行首序号
    if (p >= end || *p != ' ') return NO;
    while (p < end && *p == ' ') p++;
    const char *t0 = p;                                     // 分区标记 @bar/@tab/...
    while (p < end && *p != ' ') p++;
    if (p <= t0 || (size_t)(p - t0) >= sizeof e->tag) return NO;
    memcpy(e->tag, t0, (size_t)(p - t0));
    e->tag[p - t0] = 0;
    while (p < end && *p == ' ') p++;
    while (p < end && *p != '|') p++;                       // 类名
    if (p >= end) return NO;
    p++;
    {                                                       // 矩形
        char rb[44];
        size_t k = 0;
        while (p < end && *p != '|' && k + 1 < sizeof rb) rb[k++] = *p++;
        rb[k] = 0;
        if (sscanf(rb, "%lf,%lf,%lfx%lf", &e->x, &e->y, &e->w, &e->h) != 4) return NO;
    }
    if (p < end) p++;
    {                                                       // 文字
        size_t k = 0;
        while (p < end && *p != '|' && *p != '\n' && k + 1 < sizeof e->txt) e->txt[k++] = *p++;
        e->txt[k] = 0;
    }
    return YES;
}

// tag 必须匹配；kw 非空时按文字包含匹配，kw 为空时按序号取第 idx 个
static BOOL sbSnapFind(const char *snap, const char *tag, const char *kw, int idx,
                       double *cx, double *cy, char *what, size_t wn) {
    int hit = 0;
    const char *p = snap;
    while (p && *p) {
        const char *nl = strchr(p, '\n');
        size_t len = nl ? (size_t)(nl - p) : strlen(p);
        SBEl e;
        if (len && sbElParse(p, len, &e) && strcmp(e.tag, tag) == 0) {
            BOOL use = NO;
            if (kw && *kw) use = (strstr(e.txt, kw) != NULL);
            else { if (hit == idx) use = YES; hit++; }
            if (use) {
                *cx = e.x + e.w / 2.0;
                *cy = e.y + e.h / 2.0;
                if (what && wn) { snprintf(what, wn, "%s", e.txt); }
                return YES;
            }
        }
        if (!nl) break;
        p = nl + 1;
    }
    return NO;
}

// 从模型那行 JSON 里取一个字段（字符串或数字；没有就返回 NO）
static BOOL sbJVal(const char *js, const char *key, char *outv, size_t n) {
    if (outv && n) outv[0] = 0;
    if (!js || !*js) return NO;
    char pat[48];
    snprintf(pat, sizeof pat, "\"%s\"", key);
    const char *p = strstr(js, pat);
    if (!p) return NO;
    p += strlen(pat);
    while (*p && *p != ':') p++;
    if (!*p) return NO;
    p++;
    while (*p == ' ' || *p == '\t') p++;
    if (*p == '"') {
        p++;
        size_t k = 0;
        while (*p && *p != '"' && k + 1 < n) {
            if (*p == '\\' && p[1]) p++;
            outv[k++] = *p++;
        }
        outv[k] = 0;
        return YES;
    }
    size_t k = 0;
    while (*p && *p != ',' && *p != '}' && *p != ' ' && k + 1 < n) outv[k++] = *p++;
    outv[k] = 0;
    return k > 0;
}

static void sbJsonEscape(const char *in, char *out, size_t n) {
    size_t k = 0;
    for (const char *p = in; p && *p && k + 1 < n; p++) {
        if (*p == '"' || *p == '\\') { if (k + 2 < n) { out[k++] = '\\'; out[k++] = *p; } }
        else if (*p == '\n' || *p == '\r') { if (k + 2 < n) { out[k++] = '\\'; out[k++] = 'n'; } }
        else out[k++] = *p;
    }
    out[k] = 0;
}

// 返回值：0 = 执行了动作；1 = 只说话没动手；<0 出错。out 里放给用户的一句话
int SBDoAct(const char *instruction, char *out, size_t outLen) {
    if (out && outLen) out[0] = 0;
    if (!instruction || !*instruction) return -1;

    char snap[2600];
    snap[0] = 0;
    int rc = SBAppActSync("tree", snap, sizeof snap);
    SBLogSync("AI tree rc=%d len=%lu", rc, (unsigned long)strlen(snap));
    if (rc != 0) { snprintf(out, outLen, "微信没醒（rc=%d）", rc); return rc; }

    // 注意：这个进程里 @"..." 常量串会 SIGBUS（__cfstring 落不进 fixup 链），
    // 所有字符串一律 SBStr() 运行时构造。本段曾因这个坑把 SpringBoard 崩了一次。
    NSMutableString *pr = [NSMutableString string];
    [pr appendString:SBStr("你在 iPhone 里代替用户操作微信。当前屏幕元素清单如下，每行格式：序号 分区 类名|矩形|文字|可点\n")];
    [pr appendString:SBStr("分区含义：@bar=搜索栏  @tab=底部标签(i 从 0 开始，顺序是 微信/通讯录/发现/我)  @list=会话行  @el=其他元素\n\n")];
    [pr appendFormat:SBStr("%s\n\n"), snap];
    [pr appendFormat:SBStr("用户要求：%s\n\n"), instruction];
    [pr appendString:SBStr("只输出一行 JSON，从下面动作里选一个最合适的：\n"
                           "{\"act\":\"tap\",\"kw\":\"文字里的关键词\"}\n"
                           "{\"act\":\"tab\",\"i\":0}\n"
                           "{\"act\":\"cell\",\"i\":1}\n"
                           "{\"act\":\"scroll\",\"dir\":\"up\"}\n"
                           "{\"act\":\"type\",\"text\":\"要输入的内容\"}\n"
                           "{\"act\":\"say\",\"say\":\"直接回答用户的一句话\"}\n"
                           "规则：不要输出坐标，不要解释，不要多行，不要 markdown。找不到能做的就直接用 say。")];

    id err = nil;
    id ans = SBNetPostSync(pr, 20.0, &err);
    if (!ans) {
        const char *e = err ? (const char *)SBMsgC(err, "UTF8String") : "?";
        SBLogSync("AI net err=%s", e ? e : "?");
        snprintf(out, outLen, "模型没答上（%s）", e ? e : "?");
        return -2;
    }
    const char *js = (const char *)SBMsgC(ans, "UTF8String");
    SBLogSync("AI ans=<%s>", js ? js : "");

    char act[24], kw[120], txt[160], dir[16], iv[16], say[200];
    act[0] = kw[0] = txt[0] = dir[0] = iv[0] = say[0] = 0;
    sbJVal(js, "act", act, sizeof act);
    sbJVal(js, "kw", kw, sizeof kw);
    sbJVal(js, "text", txt, sizeof txt);
    sbJVal(js, "dir", dir, sizeof dir);
    sbJVal(js, "i", iv, sizeof iv);
    sbJVal(js, "say", say, sizeof say);

    if (!*act) {
        // 模型没听话（输出了散文）——整句当回答念，不动手
        snprintf(out, outLen, "%s", js ? js : "没听懂");
        return 1;
    }
    if (strcmp(act, "say") == 0) {
        snprintf(out, outLen, "%s", *say ? say : "这个我现在做不了");
        return 1;
    }

    char cmd[220];
    char what[140];
    what[0] = 0;
    cmd[0] = 0;
    double cx = 0, cy = 0;
    int idx = *iv ? atoi(iv) : 0;

    if (strcmp(act, "tap") == 0) {
        if (!sbSnapFind(snap, "@bar", kw, 0, &cx, &cy, what, sizeof what) &&
            !sbSnapFind(snap, "@tab", kw, 0, &cx, &cy, what, sizeof what) &&
            !sbSnapFind(snap, "@list", kw, 0, &cx, &cy, what, sizeof what) &&
            !sbSnapFind(snap, "@el", kw, 0, &cx, &cy, what, sizeof what)) {
            snprintf(out, outLen, "屏幕上没找到「%s」", kw);
            return -3;
        }
        snprintf(cmd, sizeof cmd, "touch:%.0f,%.0f", cx, cy);
    } else if (strcmp(act, "tab") == 0) {
        if (!sbSnapFind(snap, "@tab", NULL, idx, &cx, &cy, what, sizeof what)) {
            snprintf(out, outLen, "底部没有第 %d 个标签", idx);
            return -3;
        }
        snprintf(cmd, sizeof cmd, "touch:%.0f,%.0f", cx, cy);
    } else if (strcmp(act, "cell") == 0) {
        if (!sbSnapFind(snap, "@list", NULL, idx, &cx, &cy, what, sizeof what)) {
            snprintf(out, outLen, "列表里没有第 %d 行", idx);
            return -3;
        }
        snprintf(cmd, sizeof cmd, "touch:%.0f,%.0f", cx, cy);
    } else if (strcmp(act, "scroll") == 0) {
        // 窗口 430x932，tab 在 y=843；列表区从 140 到 830
        if (strcmp(dir, "down") == 0) snprintf(cmd, sizeof cmd, "drag:215,300,215,620");
        else snprintf(cmd, sizeof cmd, "drag:215,620,215,300");
        snprintf(what, sizeof what, "滑动%s", strcmp(dir, "down") == 0 ? "向下" : "向上");
    } else if (strcmp(act, "type") == 0) {
        char esc[200];
        sbJsonEscape(txt, esc, sizeof esc);
        snprintf(cmd, sizeof cmd, "seq:focus;text;type:%s;text;send;text", esc);
        snprintf(what, sizeof what, "输入「%s」", txt);
    } else {
        snprintf(out, outLen, "不支持的动作：%s", act);
        return -4;
    }

    char rep[1600];
    rep[0] = 0;
    int arc = SBAppActSync(cmd, rep, sizeof rep);
    SBLogSync("AI do <%s> rc=%d -> <%s>", cmd, arc, rep);
    sleep(1);
    sleep(1);

    // 回环：动作做完再拍一张，让模型看着新画面说一句
    char snap2[2600];
    snap2[0] = 0;
    int rc2 = SBAppActSync("tree", snap2, sizeof snap2);
    SBLogSync("AI tree2 rc=%d", rc2);

    NSMutableString *pr2 = [NSMutableString string];
    [pr2 appendString:SBStr("你刚替用户在微信里执行了一个动作，这是执行后的新屏幕：\n\n")];
    if (rc2 == 0) [pr2 appendFormat:SBStr("%s\n\n"), snap2];
    else [pr2 appendString:SBStr("（取快照失败）\n\n")];
    [pr2 appendFormat:SBStr("用户要求：%s\n你执行了：%s（%s）\n\n"), instruction, what, cmd];
    [pr2 appendString:SBStr("用一句不超过 20 字的中文，告诉用户现在的结果。只输出这句话本身，不要 JSON，不要解释。")];

    id err2 = nil;
    id ans2 = SBNetPostSync(pr2, 20.0, &err2);
    if (ans2) {
        const char *s2 = (const char *)SBMsgC(ans2, "UTF8String");
        SBLogSync("AI say2=<%s>", s2 ? s2 : "");
        if (s2 && *s2) { snprintf(out, outLen, "%s", s2); return 0; }
    }
    snprintf(out, outLen, "已%s", what);
    return 0;
}


