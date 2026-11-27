#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <unistd.h>
#include <notify.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <errno.h>
#include <arpa/inet.h>

// SiriBridge App 侧执行器 0.0.1
// 第一条竖线只做三件事：证明注入成功、能注册 IPC 端口、能回报当前前台 VC。
// 不做任何 UI 改写、不 hook 微信自己的方法，注入失败也不会影响微信本身。

#define SBAPP_PORT "com.apple.SiriBridge.app"
#define SBAPP_SB_PORT "com.apple.SiriBridge.ipc"
#define SBAPP_HELLO "com.doubao.apphello"
#define SBAPP_LOG_MAX 768

// 日志写进本 App 自己的 Documents（沙盒容器的真实路径，root shell 直接可读），
// 不走 notify —— App 侧没有那套 32 槽通道，也不需要。
static void AL(const char *fmt, ...) {
    char buf[SBAPP_LOG_MAX];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);

    char path[512];
    const char *home = getenv("HOME");
    if (!home || !*home) {
        snprintf(path, sizeof path, "/tmp/sbapp.log");
    } else {
        snprintf(path, sizeof path, "%s/Documents/sbapp.log", home);
    }
    FILE *f = fopen(path, "a");
    if (f) {
        fprintf(f, "%s\n", buf);
        fclose(f);
    }
}

// 前台 VC 的类名：先走 scene 的 keyWindow，退回 keyWindow 老路径。
static NSString *SBAppTopVCName(void) {
    @try {
        UIApplication *app = [UIApplication sharedApplication];
        if (!app) return @"noapp";

        UIViewController *vc = nil;
        if (@available(iOS 13.0, *)) {
            for (UIScene *sc in app.connectedScenes) {
                if (![sc isKindOfClass:[UIWindowScene class]]) continue;
                for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                    if (w.isKeyWindow) { vc = w.rootViewController; break; }
                }
                if (vc) break;
            }
        }
        if (!vc) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            vc = app.keyWindow.rootViewController;
#pragma clang diagnostic pop
        }
        if (!vc) return @"novc";

        // 往下钻两层，拿到真正在显示的那一层（微信多为 UINavigationController 包一层）
        for (int i = 0; i < 2 && vc; i++) {
            UIViewController *next = nil;
            if (vc.presentedViewController) next = vc.presentedViewController;
            else if ([vc isKindOfClass:[UINavigationController class]])
                next = ((UINavigationController *)vc).topViewController;
            else if ([vc isKindOfClass:[UITabBarController class]])
                next = ((UITabBarController *)vc).selectedViewController;
            if (!next) break;
            vc = next;
        }
        NSString *n = NSStringFromClass([vc class]);
        return n.length ? n : @"noname";
    } @catch (NSException *e) {
        return @"exc";
    }
}

static int SBAppCountTree(UIView *v) {
    if (!v) return 0;
    int n = 1;
    if (n >= 4000) return n;
    for (UIView *s in v.subviews) {
        n += SBAppCountTree(s);
        if (n >= 4000) break;
    }
    return n;
}

// 统计一次当前窗口里的视图数量，用来判断“能不能真的摸到它的层级”
static int SBAppCountViews(void) {
    @try {
        UIApplication *app = [UIApplication sharedApplication];
        UIWindow *kw = nil;
        if (@available(iOS 13.0, *)) {
            for (UIScene *sc in app.connectedScenes) {
                if (![sc isKindOfClass:[UIWindowScene class]]) continue;
                for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                    if (w.isKeyWindow) { kw = w; break; }
                }
                if (kw) break;
            }
        }
        if (!kw) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            kw = app.keyWindow;
#pragma clang diagnostic pop
        }
        if (!kw) return -1;
        return SBAppCountTree(kw);
    } @catch (NSException *e) {
        return -2;
    }
}

// 端口回调：收到一条 UTF-8 命令，回一条 UTF-8 结果。
// 非 ARC 工程，返回值用一个 CFDataRef 交给调用方接管。
static CFDataRef SBAppPortCallback(CFMessagePortRef local, SInt32 msgid, CFDataRef data, void *info) {
    char cmd[160] = "";
    if (data) {
        CFIndex n = CFDataGetLength(data);
        if (n > (CFIndex)sizeof(cmd) - 1) n = sizeof(cmd) - 1;
        CFDataGetBytes(data, CFRangeMake(0, n), (UInt8 *)cmd);
        cmd[n] = 0;
    }
    AL("PORT in msgid=%d cmd=<%s>", (int)msgid, cmd);

    char out[512];
    if (!strcmp(cmd, "ping")) {
        NSString *vc = SBAppTopVCName();
        snprintf(out, sizeof out, "pong vc=%s views=%d pid=%d",
                 [vc UTF8String], SBAppCountViews(), (int)getpid());
    } else if (!strcmp(cmd, "vc")) {
        NSString *vc = SBAppTopVCName();
        snprintf(out, sizeof out, "vc=%s", [vc UTF8String]);
    } else if (!strcmp(cmd, "views")) {
        snprintf(out, sizeof out, "views=%d", SBAppCountViews());
    } else {
        snprintf(out, sizeof out, "unknown cmd");
    }
    AL("PORT out <%s>", out);
    return CFDataCreate(NULL, (const UInt8 *)out, (CFIndex)strlen(out));
}

static CFMessagePortRef g_localPort = NULL;

// 1.6.30：mach 端口在 App 侧两头都被沙盒拒了（local 建不了、remote lookup 也拒），
// 换成 Unix domain socket —— 建在自己容器 Documents 里，SpringBoard 只要能看到容器就能连。
static int g_sockFd = -1;
static char g_sockPath[420];

static void SBAppHandleLine(int fd, const char *cmd) {
    char out[600];
    if (!strcmp(cmd, "ping")) {
        NSString *vc = SBAppTopVCName();
        snprintf(out, sizeof out, "pong vc=%s views=%d pid=%d",
                 [vc UTF8String], SBAppCountViews(), (int)getpid());
    } else if (!strcmp(cmd, "vc")) {
        NSString *vc = SBAppTopVCName();
        snprintf(out, sizeof out, "vc=%s", [vc UTF8String]);
    } else if (!strcmp(cmd, "views")) {
        snprintf(out, sizeof out, "views=%d", SBAppCountViews());
    } else {
        snprintf(out, sizeof out, "unknown cmd");
    }
    send(fd, out, strlen(out), 0);
    AL("SOCK out <%s>", out);
}

static void SBAppAcceptLoop(void) {
    while (1) {
        int c = accept(g_sockFd, NULL, NULL);
        if (c < 0) {
            if (errno == EINTR) continue;
            AL("SOCK accept fail errno=%d", errno);
            break;
        }
        char buf[200];
        ssize_t n = recv(c, buf, sizeof(buf) - 1, 0);
        if (n > 0) {
            buf[n] = 0;
            AL("SOCK in <%s>", buf);
            SBAppHandleLine(c, buf);
        }
        close(c);
    }
}

static void SBAppStartSocket(void) {
    if (g_sockFd >= 0) return;
    const char *home = getenv("HOME");
    if (!home) { AL("SOCK nohome"); return; }
    snprintf(g_sockPath, sizeof g_sockPath, "%s/Documents/sb.sock", home);

    unlink(g_sockPath);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) { AL("SOCK create fail errno=%d", errno); return; }

    struct sockaddr_un sa;
    memset(&sa, 0, sizeof sa);
    sa.sun_family = AF_UNIX;
    snprintf(sa.sun_path, sizeof sa.sun_path, "%s", g_sockPath);
    if (bind(fd, (struct sockaddr *)&sa, sizeof sa) < 0) {
        AL("SOCK bind fail errno=%d path=%s", errno, g_sockPath);
        close(fd);
        return;
    }
    if (listen(fd, 8) < 0) {
        AL("SOCK listen fail errno=%d", errno);
        close(fd);
        return;
    }
    g_sockFd = fd;
    chmod(g_sockPath, 0666);   // 让 SpringBoard 侧不受 umask 影响
    AL("SOCK ready path=%s", g_sockPath);
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool { SBAppAcceptLoop(); }
    });
}

// 主动上报：连 SpringBoard 建好的端口（com.doubao.sbport）发一条 hello，
// 顺带 notify_post 一个信号做兜底。设备实测 App 侧建不了 local port，只能这样反着来。
static void SBAppSayHello(void) {
    NSString *vc = SBAppTopVCName();
    char msg[300];
    snprintf(msg, sizeof msg, "hello pid=%d vc=%s views=%d",
             (int)getpid(), [vc UTF8String], SBAppCountViews());

    int st = 0;
    int tok = -1;
    notify_register_check(SBAPP_HELLO, &tok);
    if (tok >= 0) {
        notify_set_state(tok, (uint64_t)getpid());
        notify_cancel(tok);
    }
    notify_post(SBAPP_HELLO);
    AL("HELLO notify_post st=%d tok=%d <%s>", st, tok, msg);

    CFStringRef nm = CFStringCreateWithCString(NULL, SBAPP_SB_PORT, kCFStringEncodingUTF8);
    CFMessagePortRef rp = nm ? CFMessagePortCreateRemote(NULL, nm) : NULL;
    if (nm) CFRelease(nm);
    if (!rp) {
        AL("HELLO remote fail name=%s", SBAPP_SB_PORT);
        return;
    }
    CFDataRef d = CFDataCreate(NULL, (const UInt8 *)msg, (CFIndex)strlen(msg));
    CFDataRef rep = NULL;
    SInt32 rc = CFMessagePortSendRequest(rp, 2, d, 0.6, 0.6, kCFRunLoopDefaultMode, &rep);
    if (d) CFRelease(d);
    if (rc == kCFMessagePortSuccess) {
        char rb[128] = "";
        if (rep) {
            CFIndex n = CFDataGetLength(rep);
            if (n > (CFIndex)sizeof(rb) - 1) n = sizeof(rb) - 1;
            CFDataGetBytes(rep, CFRangeMake(0, n), (UInt8 *)rb);
            rb[n] = 0;
            CFRelease(rep);
        }
        AL("HELLO send ok rep=<%s>", rb);
    } else {
        AL("HELLO send rc=%d", (int)rc);
        if (rep) CFRelease(rep);
    }
    CFRelease(rp);
}

static void SBAppStartPort(void) {
    if (g_localPort) return;

    CFMessagePortContext ctx = { 0, NULL, NULL, NULL, NULL };
    CFStringRef nm2 = CFStringCreateWithCString(NULL, SBAPP_PORT, kCFStringEncodingUTF8);
    if (!nm2) { AL("PORT noname"); return; }
    CFMessagePortRef port = CFMessagePortCreateLocal(NULL, nm2,
                                                     SBAppPortCallback, &ctx, NULL);
    CFRelease(nm2);
    if (!port) {
        AL("PORT create fail name=%s", SBAPP_PORT);
        return;
    }
    CFRunLoopSourceRef src = CFMessagePortCreateRunLoopSource(NULL, port, 0);
    if (!src) {
        AL("PORT source fail");
        CFRelease(port);
        return;
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopCommonModes);
    CFRelease(src);
    g_localPort = port;
    AL("PORT ready name=%s vc=%s", SBAPP_PORT, [SBAppTopVCName() UTF8String]);
}

__attribute__((constructor))
static void SBAppInit(void) {
    @autoreleasepool {
        NSBundle *mb = [NSBundle mainBundle];
        NSString *bid = [mb bundleIdentifier];
        AL("BOOT app pid=%d bid=%s home=%s", (int)getpid(),
           bid ? [bid UTF8String] : "(nil)", getenv("HOME") ? getenv("HOME") : "(nil)");

        // 只管微信；别的 App 一律不做事（plist 里也只放行了 com.tencent.xin，这里是双保险）
        if (![bid isEqualToString:@"com.tencent.xin"]) {
            AL("BOOT skip bid=%s", bid ? [bid UTF8String] : "(nil)");
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            @autoreleasepool {
                SBAppStartPort();
                SBAppStartSocket();
                // 等 UI 起来一点点再 hello，太早取不到 keyWindow
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    @autoreleasepool { SBAppSayHello(); }
                });
            }
        });
    }
}
