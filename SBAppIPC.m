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
    int clk;        // 这一点真能点到吗（'c'=能，'x'=被盖住/在屏幕外；无标记按能点算）
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
    e->clk = 1;                                             // 没带标记的元素按"能点"算
    if (p < end && *p == '|') {
        p++;
        while (p < end && *p != '\n') {
            if (*p == 'x') e->clk = 0;
            else if (*p == 'c') e->clk = 1;
            p++;
        }
    }
    return YES;
}

// tag 必须匹配；kw 非空时按文字包含匹配，kw 为空时按序号取第 idx 个
// 两遍：先只认真能点到的元素（快照里 |c），一遍找不到再放宽到被盖住/在屏幕外的
static BOOL sbSnapFind(const char *snap, const char *tag, const char *kw, int idx,
                       double *cx, double *cy, char *what, size_t wn) {
    for (int pass = 0; pass < 2; pass++) {
        int hit = 0;
        const char *p = snap;
        while (p && *p) {
            const char *nl = strchr(p, '\n');
            size_t len = nl ? (size_t)(nl - p) : strlen(p);
            SBEl e;
            if (len && sbElParse(p, len, &e) && strcmp(e.tag, tag) == 0) {
                if (pass == 0 && !e.clk) {
                    // 被盖住的先跳过
                } else {
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
            }
            if (!nl) break;
            p = nl + 1;
        }
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

// 每轮诊断落盘：快照 / 模型原答 / 命令 / 回执 / 新快照。只给排查用，不进朗读。
static void sbActLog(const char *s, int reset) {
    if (!s) return;
    FILE *f = fopen("/var/mobile/Library/SiriBridge/act.log", reset ? "w" : "a");
    if (!f) return;
    fwrite(s, 1, strlen(s), f);
    fclose(f);
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

// 把「动作」翻译成 sbapp 能执行的一条命令；oy 回传目标的中心 y（用于判断是否在屏幕外）
static int sbResolveCmd(const char *snap, const char *act, const char *kw, int idx, const char *dir,
                        char *cmd, size_t cn, char *what, size_t wn, double *oy) {
    double cx = 0, cy = 0;
    if (what && wn) what[0] = 0;
    if (oy) *oy = 0;
    if (strcmp(act, "tap") == 0) {
        if (!kw || !*kw) return -3;
        // 只按文字找：先找普通元素，再找输入区。不预设任何 App 的控件类型。
        if (!sbSnapFind(snap, "@el", kw, 0, &cx, &cy, what, wn) &&
            !sbSnapFind(snap, "@input", kw, 0, &cx, &cy, what, wn)) return -3;
        snprintf(cmd, cn, "touch:%.0f,%.0f", cx, cy);
    } else if (strcmp(act, "el") == 0 || strcmp(act, "tab") == 0 ||
               strcmp(act, "cell") == 0 || strcmp(act, "list") == 0) {
        // 同名多条时按清单序号取；旧说法 tab/cell/list 一律并到这里
        if (!sbSnapFind(snap, "@el", NULL, idx, &cx, &cy, what, wn)) return -3;
        snprintf(cmd, cn, "touch:%.0f,%.0f", cx, cy);
    } else if (strcmp(act, "scroll") == 0) {
        // 拖动区间只跟屏幕尺寸有关（iPhone 16 Pro Max 430x932），与哪个 App、哪种布局无关
        double W = 430, H = 932, midX = W * 0.5, loY = H * 0.34, hiY = H * 0.66;
        if (dir && strcmp(dir, "down") == 0)
            snprintf(cmd, cn, "drag:%.0f,%.0f,%.0f,%.0f", midX, loY, midX, hiY);
        else
            snprintf(cmd, cn, "drag:%.0f,%.0f,%.0f,%.0f", midX, hiY, midX, loY);
        snprintf(what, wn, "滑动%s", (dir && strcmp(dir, "down") == 0) ? "向下" : "向上");
        cy = H * 0.5;
    } else if (strcmp(act, "back") == 0) {
        // 左边缘右滑 = 系统返回手势，全 App 通用
        snprintf(cmd, cn, "drag:2,430,250,430");
        snprintf(what, wn, "返回上一页");
        cy = 430;
    } else if (strcmp(act, "send") == 0) {
        // 发送：走 App 侧原有的 send（点发送键 / 触发回车）
        snprintf(cmd, cn, "send");
        snprintf(what, wn, "发送");
        cy = 449;
    } else if (strcmp(act, "type") == 0) {
        char esc[200];
        sbJsonEscape(kw, esc, sizeof esc);
        double bx = 0, by = 0;
        char w2[140];
        if (sbSnapFind(snap, "@input", NULL, 0, &bx, &by, w2, sizeof w2)) {
            // 先真触摸点开输入区让它成为第一响应者，再写入（微信那个"影子输入框"就是靠这步解决的）
            snprintf(cmd, cn, "seq:touch:%.0f,%.0f;type:%s", bx, by, esc);
            snprintf(what, wn, "在输入区写入「%s」", kw);
        } else {
            snprintf(cmd, cn, "seq:focus;text;type:%s;text;send;text", esc);
            snprintf(what, wn, "输入「%s」", kw);
        }
        cy = 449;
    } else {
        return -4;
    }
    if (oy) *oy = cy;
    return 0;
}

// 拼一轮的提示词：最终目标 + 已做步骤 + 当前快照 + 动作格式
static NSMutableString *sbPromptBuild(const char *instruction, const char *history, const char *snap) {
    NSMutableString *pr = [NSMutableString string];
    [pr appendString:SBStr("你在 iPhone 上代替用户点屏幕，操作的是当前前台这个 App（不一定是微信）。可以连续做多步，每次只做一个动作，做完会重新给你一张屏幕。\n")];
    [pr appendString:SBStr("用户最终要求：")];
    [pr appendString:SBStr(instruction)];
    [pr appendString:SBStr("\n\n")];
    if (history && *history) {
        [pr appendString:SBStr("已经做过的步骤：\n")];
        [pr appendString:SBStr(history)];
        [pr appendString:SBStr("\n")];
    }
    [pr appendString:SBStr("当前屏幕元素清单（每行：序号 分区 类名|矩形|文字|可点）：\n")];
    [pr appendString:SBStr("@input=可编辑输入区  @el=屏幕上带文字的元素（按从上到下的顺序排）\n")];
    [pr appendString:SBStr("行尾 |c 表示这一点真能点到；|x 表示被别的界面盖住或已滑出屏幕，别点它。\n")];
    [pr appendString:SBStr(snap)];
    [pr appendString:SBStr("\n\n")];
    [pr appendString:SBStr("动作格式（只输出一行 JSON，一次只做一个）：\n"
                           "{\"act\":\"tap\",\"kw\":\"清单里的一条文字\"}\n"
                           "{\"act\":\"el\",\"i\":0}\n"
                           "{\"act\":\"scroll\",\"dir\":\"up\"}\n"
                           "{\"act\":\"type\",\"text\":\"要输入的内容\"}\n"
                           "{\"act\":\"send\"}\n"
                           "{\"act\":\"back\"}\n"
                           "{\"act\":\"say\",\"say\":\"给用户的一句话\"}\n"
                           "规则：用户说的东西要先在清单里找到它写的字，再 tap，kw 填那条文字（只填文字，不要序号）；"
                           "同名有好几条时用 el 加 i 区分（i 是清单序号，从 0 开始）。"
                           "清单里没有用户说的东西、但下面可能还有内容时，用 scroll 找一轮再看新清单；"
                           "scroll 之后仍然没有，就 say 说这页没有这个东西，不要硬点别的。"
                           "要打字用 type（执行器会自己找到输入区点开），写完要发出去用 send，退出当前页面用 back。"
                           "整个目标已经达成、或者确实做不到时，用 say 说一句收尾 —— 这是唯一能结束的方式。"
                           "不要输出坐标，不要解释，不要多行，不要 markdown。")];
    return pr;
}

// 做一步。
// spoken：没结束时放这一步做了什么（进历史）；ending 时放收尾那句话。
// 返回 0 = 正常（看 ended）；<0 出错（spoken 是错误说明）
static int sbActStep(const char *instruction, const char *history, char *spoken, size_t sn, int *ended) {
    if (spoken && sn) spoken[0] = 0;
    if (ended) *ended = 0;

    char snap[2600];
    snap[0] = 0;
    int rc = SBAppActSync("tree", snap, sizeof snap);
    SBLogSync("AI tree rc=%d len=%lu", rc, (unsigned long)strlen(snap));
    if (rc != 0) { snprintf(spoken, sn, "微信没醒（rc=%d）", rc); return rc; }
    sbActLog("SNAP\n", 0);
    sbActLog(snap, 0);
    sbActLog("\n", 0);

    NSMutableString *pr = sbPromptBuild(instruction, history, snap);
    const char *p8 = (const char *)SBMsgC(pr, "UTF8String");
    sbActLog("PROMPT\n", 0);
    sbActLog(p8 ? p8 : "?", 0);
    sbActLog("\n", 0);

    id err = nil;
    id ans = SBNetPostSync(pr, 22.0, &err);
    if (!ans) {
        const char *e = err ? (const char *)SBMsgC(err, "UTF8String") : "?";
        SBLogSync("AI net err=%s", e ? e : "?");
        snprintf(spoken, sn, "模型没答上（%s）", e ? e : "?");
        return -2;
    }
    const char *js = (const char *)SBMsgC(ans, "UTF8String");
    SBLogSync("AI ans=<%s>", js ? js : "");
    sbActLog("ANS\n", 0);
    sbActLog(js ? js : "?", 0);
    sbActLog("\n", 0);

    char act[24], kw[120], txt[160], dir[16], iv[16], say[220];
    act[0] = kw[0] = txt[0] = dir[0] = iv[0] = say[0] = 0;
    sbJVal(js, "act", act, sizeof act);
    sbJVal(js, "kw", kw, sizeof kw);
    sbJVal(js, "text", txt, sizeof txt);
    sbJVal(js, "dir", dir, sizeof dir);
    sbJVal(js, "i", iv, sizeof iv);
    sbJVal(js, "say", say, sizeof say);

    if (!*act) {
        // 模型没按格式输出（回了一段话）——当收尾念掉，不再动手
        snprintf(spoken, sn, "%s", js ? js : "没听懂");
        if (ended) *ended = 1;
        return 0;
    }
    if (strcmp(act, "say") == 0) {
        snprintf(spoken, sn, "%s", *say ? say : "好了");
        if (ended) *ended = 1;
        return 0;
    }

    char cmd[220];
    char what[140];
    cmd[0] = 0;
    what[0] = 0;
    double cy = 0;
    int idx = *iv ? atoi(iv) : 0;
    const char *arg = (strcmp(act, "type") == 0) ? txt : kw;

    int rr = sbResolveCmd(snap, act, arg, idx, dir, cmd, sizeof cmd, what, sizeof what, &cy);
    if (rr != 0) {
        // 这一步做不成：说清楚就结束，别空转
        snprintf(spoken, sn, "屏幕上没找到「%s」", arg);
        if (ended) *ended = 1;
        return 0;
    }

    // 目标在屏幕外（首页搜索栏被列表滑走了）→ 先把列表拉回顶部，再重拍一次重算
    if (cy < 60 || cy > 925) {
        SBLogSync("AI offscreen cy=%.0f, scroll to top", cy);
        char r0[400];
        r0[0] = 0;
        SBAppActSync("drag:215,400,215,820", r0, sizeof r0);
        sleep(1);
        snap[0] = 0;
        SBAppActSync("tree", snap, sizeof snap);
        rr = sbResolveCmd(snap, act, arg, idx, dir, cmd, sizeof cmd, what, sizeof what, &cy);
        if (rr != 0) {
            snprintf(spoken, sn, "屏幕上没找到「%s」", arg);
            if (ended) *ended = 1;
            return 0;
        }
    }

    char rep[1600];
    rep[0] = 0;
    int arc = SBAppActSync(cmd, rep, sizeof rep);
    SBLogSync("AI do <%s> rc=%d -> <%s>", cmd, arc, rep);
    {
        char b[600];
        snprintf(b, sizeof b, "CMD\n%s\n-> rc=%d %s\n", cmd, arc, rep);
        sbActLog(b, 0);
    }
    sleep(1);
    sleep(1);

    snprintf(spoken, sn, "%s（%s）", what, cmd);
    return 0;
}

// 「输入;<文本>」/「输入：<文本>」：字面直通——不调模型、不做语义理解，
// 把分隔符后面的内容原样打进当前输入区（搜索框 / @input / 兜底管线）。
// 返回 1 = 已经处理完（out 放回执）；0 = 不是这种指令，交回正常 AI 流程
static int sbDoTypeLiteral(const char *instruction, char *out, size_t outLen) {
    const char *txt = NULL;
    const char *p1 = "输入;";
    const char *p2 = "输入：";
    if (strncmp(instruction, p1, strlen(p1)) == 0) txt = instruction + strlen(p1);
    else if (strncmp(instruction, p2, strlen(p2)) == 0) txt = instruction + strlen(p2);
    if (!txt) return 0;

    while (*txt == ' ' || *txt == '\t') txt++;
    if (!*txt) {
        snprintf(out, outLen, "「输入;」后面没给文本");
        return 1;
    }

    char snap[2600];
    snap[0] = 0;
    int rc = SBAppActSync("tree", snap, sizeof snap);
    SBLogSync("TYPE tree rc=%d len=%lu", rc, (unsigned long)strlen(snap));
    if (rc != 0) {
        snprintf(out, outLen, "微信没醒（rc=%d）", rc);
        return 1;
    }
    sbActLog("SNAP(type)\n", 0);
    sbActLog(snap, 0);
    sbActLog("\n", 0);

    char cmd[300], what[200];
    double cy = 0;
    what[0] = 0;
    int rr = sbResolveCmd(snap, "type", txt, 0, "", cmd, sizeof cmd, what, sizeof what, &cy);
    if (rr != 0) {
        snprintf(out, outLen, "没有可写入的输入区");
        return 1;
    }

    char rep[1600];
    rep[0] = 0;
    int arc = SBAppActSync(cmd, rep, sizeof rep);
    SBLogSync("TYPE do <%s> rc=%d -> <%s>", cmd, arc, rep);
    {
        char b[600];
        snprintf(b, sizeof b, "CMD\n%s\n-> rc=%d %s\n", cmd, arc, rep);
        sbActLog(b, 0);
    }
    if (arc == 0) snprintf(out, outLen, "%s", what[0] ? what : "已输入");
    else snprintf(out, outLen, "输入失败（rc=%d）", arc);
    return 1;
}

// 多轮执行：最多 5 步，最后让模型收一句
// 返回 0 = 做了动作并被收尾；1 = 直接说了话；<0 出错
int SBDoAct(const char *instruction, char *out, size_t outLen) {
    if (out && outLen) out[0] = 0;
    if (!instruction || !*instruction) return -1;

    char hist[800];
    hist[0] = 0;
    {
        char h2[320];
        snprintf(h2, sizeof h2, "INST<%s> len=%lu\n", instruction, (unsigned long)strlen(instruction));
        sbActLog(h2, 1);
    }

    // 字面输入直通：命中就绕开模型，一步到位
    if (sbDoTypeLiteral(instruction, out, outLen)) {
        SBLogSync("TYPE fast -> <%s>", out);
        return 1;
    }

    for (int round = 0; round < 5; round++) {
        char spoken[1400];
        int ended = 0;
        int rc = sbActStep(instruction, hist, spoken, sizeof spoken, &ended);
        if (rc < 0) { snprintf(out, outLen, "%s", spoken); return rc; }
        if (ended) {
            SBLogSync("AI end round=%d say=<%s>", round, spoken);
            snprintf(out, outLen, "%s", spoken);
            return 1;
        }
        size_t used = strlen(hist);
        if (used + 1 < sizeof hist) snprintf(hist + used, sizeof hist - used, "· %s\n", spoken);
        SBLogSync("AI step %d: %s", round + 1, spoken);
        sleep(1);
    }

    // 三步用完还没收尾：拍最后一张，让模型说一句
    char snap2[2600];
    snap2[0] = 0;
    int rc2 = SBAppActSync("tree", snap2, sizeof snap2);
    NSMutableString *pr2 = [NSMutableString string];
    [pr2 appendString:SBStr("你已经替用户做了这些步骤：\n")];
    [pr2 appendString:SBStr(hist)];
    [pr2 appendString:SBStr("\n当前屏幕：\n")];
    [pr2 appendString:SBStr(rc2 == 0 ? snap2 : "（取快照失败）")];
    [pr2 appendString:SBStr("\n\n用一句不超过 20 字的中文，告诉用户现在做到哪一步了；还没做完就直说。只输出这句话本身。")];

    id err2 = nil;
    id ans2 = SBNetPostSync(pr2, 22.0, &err2);
    if (ans2) {
        const char *s2 = (const char *)SBMsgC(ans2, "UTF8String");
        SBLogSync("AI sum=<%s>", s2 ? s2 : "");
        if (s2 && *s2) { snprintf(out, outLen, "%s", s2); return 0; }
    }
    snprintf(out, outLen, "走了几步还没做完");
    return 0;
}
