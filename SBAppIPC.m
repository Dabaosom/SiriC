#import "SiriBridge.h"
#include <string.h>
#include <dispatch/dispatch.h>
#include <notify.h>

// 1.6.26→1.6.28：跨进程第一步。
// 设备实测两件事：
//   ① App 进程里 CFMessagePortCreateLocal 被拒（mach-register 受沙盒限制）；
//   ② dylib 里的 CFSTR(...) 常量对象 isa 没被认证，msgSend 过去直接 SIGBUS（黑屏就是这条）。
// 所以：端口只由 SpringBoard 这一侧建（系统进程能注册），名字一律运行时 CFStringCreateWithCString 构造，
// 绝不碰 CFSTR 常量；notify 兜底的 block 也撤掉（block 字面量同样有 PAC 风险）。
#define SBAPP_PORT   "com.apple.SiriBridge.ipc"
#define SBAPP_APP_PORT "com.apple.SiriBridge.app"

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
    notify_register_dispatch(SBAPP_HELLO, &g_helloTok, dispatch_get_main_queue(), ^(int t) {
        uint64_t pid = 0;
        notify_get_state(t, &pid);
        SBLogSync("APP hello notify pid=%llu", (unsigned long long)pid);
    });
    SBLogSync("APP hello watch tok=%d", g_helloTok);
}

// 探一次 App 侧端口（当前 App 侧建不起来，留着看后面有没有变化）
void SBAppPingAsync(const char *why) {
    const char *w = why ? why : "";
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        CFStringRef nm = SBPortName(SBAPP_APP_PORT);
        if (!nm) { SBLogSync("APP port noname (%s)", w); return; }
        CFMessagePortRef remote = CFMessagePortCreateRemote(NULL, nm);
        CFRelease(nm);
        if (!remote) {
            SBLogSync("APP port none (%s)", w);
            return;
        }
        const char *req = "ping";
        CFDataRef d = CFDataCreate(NULL, (const UInt8 *)req, (CFIndex)strlen(req));
        CFDataRef rep = NULL;
        SInt32 rc = CFMessagePortSendRequest(remote, 1, d, 0.4, 0.4,
                                             kCFRunLoopDefaultMode, &rep);
        if (d) CFRelease(d);
        if (rc == kCFMessagePortSuccess && rep) {
            CFIndex n = CFDataGetLength(rep);
            char buf[256];
            if (n > (CFIndex)sizeof(buf) - 1) n = sizeof(buf) - 1;
            CFDataGetBytes(rep, CFRangeMake(0, n), (UInt8 *)buf);
            buf[n] = 0;
            SBLogSync("APP pong <%s> (%s)", buf, w);
            CFRelease(rep);
        } else {
            SBLogSync("APP send rc=%d (%s)", (int)rc, w);
        }
        CFRelease(remote);
    });
}
