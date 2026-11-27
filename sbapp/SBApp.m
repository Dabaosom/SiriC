#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/message.h>
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

// ============ 1.6.31：按文字找控件（只报告，不点击）============
// 一个控件上的“文字”可能藏在好几个地方：accessibilityLabel、按钮 title、文本输入框 placeholder、
// 标签 text。按顺序取第一个非空的，再和关键词做子串匹配。
static NSString *SBAppTextOf(UIView *v) {
    @try {
        if ([v respondsToSelector:@selector(accessibilityLabel)]) {
            NSString *l = [v accessibilityLabel];
            if ([l isKindOfClass:[NSString class]] && l.length) return l;
        }
        if ([v isKindOfClass:[UIButton class]]) {
            NSString *t = [(UIButton *)v currentTitle];
            if (t.length) return t;
        }
        if ([v isKindOfClass:[UILabel class]]) {
            NSString *t = [(UILabel *)v text];
            if (t.length) return t;
        }
        if ([v isKindOfClass:[UITextField class]]) {
            NSString *t = [(UITextField *)v placeholder];
            if (t.length) return t;
        }
        if ([v isKindOfClass:[UITextView class]]) {
            NSString *t = [(UITextView *)v text];
            if (t.length > 40) t = [t substringToIndex:40];
            if (t.length) return t;
        }
        if ([v respondsToSelector:@selector(title)]) {
            id t = [v performSelector:@selector(title)];
            if ([t isKindOfClass:[NSString class]] && [t length]) return t;
        }
    } @catch (NSException *e) {}
    return nil;
}

static void SBAppCollect(UIView *v, const char *kw, NSMutableArray *out, int *cnt) {
    if (!v || *cnt >= 6) return;
    NSString *t = SBAppTextOf(v);
    if (t) {
        const char *cs = [t UTF8String];
        if (cs && strstr(cs, kw)) {
            CGRect r = [v convertRect:v.bounds toView:nil];   // 转到窗口坐标
            BOOL clickable = [v isKindOfClass:[UIControl class]] ||
                             (v.gestureRecognizers.count > 0) ||
                             ([v isKindOfClass:[UITableView class]]);
            NSString *rec = [NSString stringWithFormat:@"%@|%.0f,%.0f,%.0f,%.0f|%@|%@",
                             NSStringFromClass([v class]),
                             r.origin.x, r.origin.y, r.size.width, r.size.height,
                             clickable ? @"T" : @"-",
                             (t.length > 24 ? [t substringToIndex:24] : t)];
            [out addObject:rec];
            (*cnt)++;
        }
    }
    for (UIView *s in v.subviews) {
        if (*cnt >= 6) break;
        SBAppCollect(s, kw, out, cnt);
    }
}

static UIWindow *SBAppKeyWindow(void);

static void SBAppCollectHit(UIView *v, const char *kw, NSMutableArray *views, int *cnt) {    if (!v || *cnt >= 6) return;
    NSString *t = SBAppTextOf(v);
    if (t) {
        const char *cs = [t UTF8String];
        if (cs && strstr(cs, kw)) { [views addObject:v]; (*cnt)++; }
    }
    for (UIView *s in v.subviews) {
        if (*cnt >= 6) break;
        SBAppCollectHit(s, kw, views, cnt);
    }
}

// 1.6.32：点击。在 App 自己的进程里，对命中的控件做“无障碍激活”，
// 或者对 UIControl 直接发 TouchUpInside。最坏结果是“没点动”，不会拖垮系统。
// 0.0.10 修正（02:03 微信 SIGSEGV 实证）：崩的不是 accessibilityActivate，
// 而是【在 socket 线程里取 keyWindow】—— 那一下本身就是非主线程访问 UIKit。
// 现在整个动作（取窗口 → 遍历 → 操作）都收进同一个主线程块里，块内不再嵌套 dispatch_sync。
static BOOL SBAppActivateOnMain(UIView *v) {
    @try {
        if ([v isKindOfClass:[UIControl class]]) {
            [(UIControl *)v sendActionsForControlEvents:UIControlEventTouchUpInside];
            return YES;
        }
        if ([v respondsToSelector:@selector(accessibilityActivate)]) {
            return [v accessibilityActivate];
        }
    } @catch (NSException *e) {}
    return NO;
}

static void SBAppTap(NSString *kw, char *out, size_t outLen) {
    out[0] = 0;
    const char *k = kw ? [kw UTF8String] : "";
    if (!k || !*k) { snprintf(out, outLen, "T nokw"); return; }

    dispatch_sync(dispatch_get_main_queue(), ^{
        @try {
            UIWindow *w = SBAppKeyWindow();
            if (!w) { snprintf(out, outLen, "T nowin"); return; }
            NSMutableArray *vs = [NSMutableArray array];
            int cnt = 0;
            SBAppCollectHit(w, k, vs, &cnt);
            if (vs.count == 0) { snprintf(out, outLen, "T notfound"); return; }
            NSMutableString *ms = [NSMutableString stringWithFormat:@"T hit=%d", cnt];
            for (UIView *v in vs) {
                NSString *cls = NSStringFromClass([v class]);
                BOOL ok = SBAppActivateOnMain(v);
                [ms appendFormat:@" %@:%@", cls, ok ? @"Y" : @"N"];
                if (ok) break;
            }
            snprintf(out, outLen, "%s", [ms UTF8String]);
        } @catch (NSException *e) { snprintf(out, outLen, "T exc"); }
    });
    AL("TAP %s", out);
}

static UIWindow *SBAppKeyWindow(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (@available(iOS 13.0, *)) {
        for (UIScene *sc in app.connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                if (w.isKeyWindow) return w;
            }
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return app.keyWindow;
#pragma clang diagnostic pop
}

// ============ 0.0.9：写入文字 / 提交 ============
// 0.0.8 只有“点”，做不了“进搜索 → 输词 → 搜”。这里补两件原子能力。
// 找目标控件的顺序：当前第一响应者（真的在输入态的那个）→ 视图树里第一个 UITextField
//（微信的 UISearchBar 内部就挂着一个 _UITextField 子类）。
static UIView *SBAppResponderIn(UIView *v) {
    if (!v) return nil;
    if ([v isFirstResponder]) return v;
    for (UIView *s in v.subviews) {
        UIView *r = SBAppResponderIn(s);
        if (r) return r;
    }
    return nil;
}

static UITextField *SBAppFieldIn(UIView *v) {
    if (!v) return nil;
    if ([v isKindOfClass:[UITextField class]]) return (UITextField *)v;
    for (UIView *s in v.subviews) {
        UITextField *f = SBAppFieldIn(s);
        if (f) return f;
    }
    return nil;
}

// 0.0.11：定“真正该写入的那个控件”。
// 实测坑：微信的 UISearchBar 自己就是 firstResponder，直接 setText 打到了 UISearchBar 上，
// 结果只改了它的显示文字，没进内部输入框，搜索也没触发。
// 所以先认 UISearchBar，如果命中的是它，继续往它内部找那个 UITextField。
static UIView *SBAppTextTargetIn(UIView *w) {
    UIView *tv = SBAppResponderIn(w);
    if (tv && [tv isKindOfClass:[UISearchBar class]]) {
        UITextField *f = SBAppFieldIn(tv);
        if (f) return f;
    }
    if (tv) return tv;
    return SBAppFieldIn(w);
}

// 0.0.13：只读 —— 把第一响应者当前的真实 text 读回来。
// 目的：分清「写没写进去」和「写进去了但微信不刷新」。这两个结论导向完全不同的修法。
static void SBAppReadText(char *out, size_t outLen) {
    out[0] = 0;
    dispatch_sync(dispatch_get_main_queue(), ^{
        @try {
            UIWindow *w = SBAppKeyWindow();
            if (!w) { snprintf(out, outLen, "TX nowin"); return; }
            UIView *tv = SBAppTextTargetIn(w);
            if (!tv) { snprintf(out, outLen, "TX none"); return; }
            NSString *cls = NSStringFromClass([tv class]);
            NSString *s = nil;
            if ([tv respondsToSelector:@selector(text)])
                s = ((id (*)(id, SEL))objc_msgSend)(tv, sel_registerName("text"));
            if (![s isKindOfClass:[NSString class]]) s = @"";
            snprintf(out, outLen, "TX %s=<%s> vc=%s",
                     cls ? [cls UTF8String] : "none",
                     [s UTF8String],
                     [SBAppTopVCName() UTF8String]);
        } @catch (NSException *e) { snprintf(out, outLen, "TX exc"); }
    });
    AL("TEXT %s", out);
}

// 0.0.12：只“拿到焦点”，不写任何东西。
// 必须单独成一步 —— 实测：微信首页搜索栏一 becomeFirstResponder 就会跳进搜索页，
// 如果紧接着在同一瞬间 setText，文字全写到了旧页面那个已经没人看的控件上，
// 新搜索页是空的（现象：键盘弹起、框里没字）。
static void SBAppFocus(char *out, size_t outLen) {
    out[0] = 0;
    dispatch_sync(dispatch_get_main_queue(), ^{
        @try {
            UIWindow *w = SBAppKeyWindow();
            if (!w) { snprintf(out, outLen, "FO nowin"); return; }
            UIView *tv = SBAppTextTargetIn(w);
            if (!tv) { snprintf(out, outLen, "FO none"); return; }
            BOOL ok = [tv becomeFirstResponder];
            NSString *vc = SBAppTopVCName();
            snprintf(out, outLen, "FO %s:%s vc=%s",
                     [NSStringFromClass([tv class]) UTF8String], ok ? "Y" : "N",
                     [vc UTF8String]);
        } @catch (NSException *e) { snprintf(out, outLen, "FO exc"); }
    });
    AL("FOCUS %s", out);
}

// 写入：0.0.12 改走 insertText。
// setText 只是改值，微信这种自绘搜索栏不刷新显示（实测框里始终无字）；
// insertText 走的是真实输入管线，会触发 shouldChange 与界面刷新。
static void SBAppType(NSString *text, char *out, size_t outLen) {
    out[0] = 0;
    if (!text.length) { snprintf(out, outLen, "TY empty"); return; }

    dispatch_sync(dispatch_get_main_queue(), ^{
        @try {
            UIWindow *w = SBAppKeyWindow();     // 必须在主线程取
            if (!w) { snprintf(out, outLen, "TY nowin"); return; }
            UIView *tv = SBAppTextTargetIn(w);  // 每次都重新找：跳页后是第一响应者变了
            if (!tv) { snprintf(out, outLen, "TY none"); return; }
            NSString *cls = NSStringFromClass([tv class]);
            NSString *vc = SBAppTopVCName();
            int ok = 0;
            if ([tv respondsToSelector:@selector(becomeFirstResponder)]) [tv becomeFirstResponder];
            if ([tv respondsToSelector:@selector(insertText:)]) {
                [tv performSelector:@selector(insertText:) withObject:text];
                ok = 2;
            } else if ([tv isKindOfClass:[UITextField class]]) {
                UITextField *f = (UITextField *)tv;
                [f setText:text];
                [f sendActionsForControlEvents:UIControlEventEditingChanged];
                ok = 1;
            } else if ([tv isKindOfClass:[UITextView class]]) {
                [(UITextView *)tv setText:text];
                ok = 1;
            } else if ([tv respondsToSelector:@selector(setText:)]) {
                [tv performSelector:@selector(setText:) withObject:text];
                ok = 1;
            }
            snprintf(out, outLen, "TY %s:%d vc=%s", cls ? [cls UTF8String] : "none", ok, [vc UTF8String]);
        } @catch (NSException *e) { snprintf(out, outLen, "TY exc"); }
    });
    AL("TYPE %s", out);
}

// 提交：0.0.11 加了微信搜索栏真正认的那个回调。
//   4 = UISearchBar 的 delegate 接了 searchBarSearchButtonClicked（微信走这条）
//   1 = UITextField 的 delegate 接了 textFieldShouldReturn
//   2 = delegate 存在但拒了
//   3 = 只发了 EditingDidEndOnExit（微信不认，实测无反应）
static void SBAppSend(char *out, size_t outLen) {
    out[0] = 0;

    dispatch_sync(dispatch_get_main_queue(), ^{
        @try {
            UIWindow *w = SBAppKeyWindow();     // 必须在主线程取
            if (!w) { snprintf(out, outLen, "SD nowin"); return; }
            UIView *tv = SBAppTextTargetIn(w);
            if (!tv) { snprintf(out, outLen, "SD none"); return; }
            NSString *cls = NSStringFromClass([tv class]);
            int ok = 0;

            // ① 往上找 UISearchBar 祖先，取它的 delegate，调搜索按钮回调
            UIView *p = tv;
            while (p && ![p isKindOfClass:[UISearchBar class]]) p = [p superview];
            if ([p isKindOfClass:[UISearchBar class]]) {
                UISearchBar *sb = (UISearchBar *)p;
                id d = [sb delegate];
                if (d && [d respondsToSelector:@selector(searchBarSearchButtonClicked:)]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(d, sel_registerName("searchBarSearchButtonClicked:"), sb);
                    ok = 4;
                }
            }

            // ①' 插入回车：走真实输入管线，等于按下键盘上的「搜索」键。
            // 微信的搜索栏是自绘的（类名 WCSearchBar，不是 UISearchBar），
            // 实测 delege 里没有 searchBarSearchButtonClicked，只有这条能触发。
            if (!ok && [tv respondsToSelector:@selector(insertText:)]) {
                [tv performSelector:@selector(insertText:) withObject:@"\n"];
                ok = 5;
            }

            // ② 文本控件的 return 回调
            if (!ok && [tv isKindOfClass:[UITextField class]]) {
                UITextField *f = (UITextField *)tv;
                id d = [f delegate];
                if (d && [d respondsToSelector:@selector(textFieldShouldReturn:)]) {
                    BOOL r = ((BOOL (*)(id, SEL, id))objc_msgSend)(d, sel_registerName("textFieldShouldReturn:"), f);
                    ok = r ? 1 : 2;
                }
                [f sendActionsForControlEvents:UIControlEventEditingDidEndOnExit];
                if (!ok) ok = 3;
            }

            snprintf(out, outLen, "SD %s:%d", cls ? [cls UTF8String] : "none", ok);
        } @catch (NSException *e) { snprintf(out, outLen, "SD exc"); }
    });
    AL("SEND %s", out);
}

static void SBAppFind(NSString *kw, char *out, size_t outLen) {
    out[0] = 0;
    const char *k = kw ? [kw UTF8String] : "";
    if (!k || !*k) { snprintf(out, outLen, "F nokw"); return; }

    dispatch_sync(dispatch_get_main_queue(), ^{
        @try {
            UIWindow *w = SBAppKeyWindow();     // 必须在主线程取
            if (!w) { snprintf(out, outLen, "F nowin"); return; }
            NSMutableArray *arr = [NSMutableArray array];
            int cnt = 0;
            SBAppCollect(w, k, arr, &cnt);
            NSMutableString *ms = [NSMutableString stringWithFormat:@"F n=%d", cnt];
            for (NSString *r in arr) [ms appendFormat:@" %@", r];
            snprintf(out, outLen, "%s", [ms UTF8String]);
        } @catch (NSException *e) { snprintf(out, outLen, "F exc"); }
    });
    AL("FIND kw=<%s> %s", k, out);
}

static CFMessagePortRef g_localPort = NULL;

// 1.6.30：mach 端口在 App 侧两头都被沙盒拒了（local 建不了、remote lookup 也拒），
// 换成 Unix domain socket —— 建在自己容器 Documents 里，SpringBoard 只要能看到容器就能连。
static int g_sockFd = -1;
static char g_sockPath[420];

// 0.0.9：把「一条命令」的执行抽出来，socket 和 seq 都能用。
// seq: 用 ';' 分隔多步，每步之间固定间隔（等键盘/转场），最多 6 步。
static void SBAppExecOne(const char *cmd, char *out, size_t outLen) {
    out[0] = 0;
    if (!cmd) { snprintf(out, outLen, "nil"); return; }

    if (!strcmp(cmd, "ping")) {
        NSString *vc = SBAppTopVCName();
        snprintf(out, outLen, "pong vc=%s views=%d pid=%d",
                 [vc UTF8String], SBAppCountViews(), (int)getpid());
    } else if (!strcmp(cmd, "vc")) {
        NSString *vc = SBAppTopVCName();
        snprintf(out, outLen, "vc=%s", [vc UTF8String]);
    } else if (!strcmp(cmd, "views")) {
        snprintf(out, outLen, "views=%d", SBAppCountViews());
    } else if (!strncmp(cmd, "find:", 5)) {
        NSString *kw = [NSString stringWithUTF8String:cmd + 5];
        @autoreleasepool { SBAppFind(kw, out, outLen); }
    } else if (!strncmp(cmd, "tap:", 4)) {
        NSString *kw = [NSString stringWithUTF8String:cmd + 4];
        @autoreleasepool { SBAppTap(kw, out, outLen); }
    } else if (!strncmp(cmd, "type:", 5)) {
        NSString *tx = [NSString stringWithUTF8String:cmd + 5];
        @autoreleasepool { SBAppType(tx, out, outLen); }
    } else if (!strcmp(cmd, "focus")) {
        @autoreleasepool { SBAppFocus(out, outLen); }
    } else if (!strcmp(cmd, "text")) {
        @autoreleasepool { SBAppReadText(out, outLen); }
    } else if (!strcmp(cmd, "send")) {
        @autoreleasepool { SBAppSend(out, outLen); }
    } else if (!strncmp(cmd, "seq:", 4)) {
        char buf[600];
        snprintf(buf, sizeof buf, "%s", cmd + 4);
        char *steps[6];
        int ns = 0;
        char *p = buf;
        while (p && *p && ns < 6) {
            char *semi = strchr(p, ';');
            if (semi) *semi = 0;
            steps[ns++] = p;
            if (!semi) break;
            p = semi + 1;
        }
        char acc[900];
        acc[0] = 0;
        for (int i = 0; i < ns; i++) {
            char r[400];
            r[0] = 0;
            SBAppExecOne(steps[i], r, sizeof r);
            AL("SEQ %d <%s> -> <%s>", i, steps[i], r);
            size_t used = strlen(acc);
            snprintf(acc + used, sizeof(acc) - used, "%s%s", i ? " | " : "", r);
            if (i + 1 < ns) usleep(1200 * 1000);   // 0.0.12：跳页动画要 1 秒上下，700ms 不够
        }
        snprintf(out, outLen, "SEQ n=%d %s", ns, acc);
    } else {
        snprintf(out, outLen, "unknown cmd");
    }
}

static void SBAppHandleLine(int fd, const char *cmd) {
    char out[1200];
    out[0] = 0;
    SBAppExecOne(cmd, out, sizeof out);
    if (!out[0]) snprintf(out, sizeof out, "empty");
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
