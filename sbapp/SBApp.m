#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <unistd.h>
#include <notify.h>

// SiriBridge App 侧执行器 0.0.1
// 第一条竖线只做三件事：证明注入成功、能注册 IPC 端口、能回报当前前台 VC。
// 不做任何 UI 改写、不 hook 微信自己的方法，注入失败也不会影响微信本身。

#define SBAPP_PORT "com.doubao.sbapp.port"
#define SBAPP_SB_PORT "com.doubao.sbport"
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

// 主动上报：连 SpringBoard 建好的端口（com.doubao.sbport）发一条 hello，
// 顺带 notify_post 一个信号做兜底。设备实测 App 侧建不了 local port，只能这样反着来。
static void SBAppSayHello(void) {
    NSString *vc = SBAppTopVCName();
    char msg[300];
    snprintf(msg, sizeof msg, "hello pid=%d vc=%s views=%d",
             (int)getpid(), [vc UTF8String], SBAppCountViews());

    int st = 0;
    notify_post(SBAPP_HELLO);
    AL("HELLO notify_post st=%d <%s>", st, msg);

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
                // 等 UI 起来一点点再 hello，太早取不到 keyWindow
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    @autoreleasepool { SBAppSayHello(); }
                });
            }
        });
    }
}
