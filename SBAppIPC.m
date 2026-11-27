#import "SiriBridge.h"
#include <string.h>
#include <dispatch/dispatch.h>
#include <notify.h>

// 1.6.26：跨进程第一步。
// 设备实测：App 进程里 CFMessagePortCreateLocal 被拒（mach-register 受沙盒限制），
// 所以换成 SpringBoard 这一侧当服务端：它本来就是系统进程，能注册端口。
// App 侧只做 remote lookup 发一条 hello，读写方向由 App 发起，更容易绕开 lookup 限制。
#define SBAPP_PORT   "com.doubao.sbport"
#define SBAPP_HELLO  "com.doubao.apphello"

static CFMessagePortRef g_sbPort = NULL;
static int g_helloTok = -1;

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
    g_sbPort = CFMessagePortCreateLocal(NULL, CFSTR(SBAPP_PORT), sbPortCallback, NULL, NULL);
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

// Darwin notify 兜底通道：即使端口不通，App 启动也能让 SpringBoard 知道一声。
void SBAppHelloWatch(void) {
    if (g_helloTok >= 0) return;
    notify_register_dispatch(SBAPP_HELLO, &g_helloTok, dispatch_get_main_queue(), ^(int t) {
        (void)t;
        SBLogSync("APP hello notify");
    });
    SBLogSync("APP hello watch tok=%d", g_helloTok);
}

// 保留的主动探测：从 SpringBoard 去连 App 侧端口（当前 App 侧建不起来，留着看后面有没有变化）
void SBAppPingAsync(const char *why) {
    const char *w = why ? why : "";
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        CFMessagePortRef remote = CFMessagePortCreateRemote(NULL, CFSTR("com.doubao.sbapp.port"));
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
