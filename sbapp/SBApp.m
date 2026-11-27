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
#include <dlfcn.h>
#include <mach/mach_time.h>
// 0.0.16：真实触摸注入（思路来自 TouchSimulator-iOS14 / Ryu0118）
#include "headers/IOHIDEvent.h"
#include "headers/IOHIDEventTypes.h"
#include "headers/IOHIDEventSystemClient.h"

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

// ============ 0.0.14：表格选中（不需要触摸）============
// 微信首页聊天列表如果是标准 UITableView，走 didSelectRow 就能“进聊天”，
// 完全不依赖任何触摸事件。这条是纯 API，比点自绘控件可靠一个档次。
// 先只探第一行，并把「有没有 UITableView / 有几行 / cell 是什么类」都报回来。
static UITableView *SBAppFindTable(UIView *v) {
    if (!v) return nil;
    if ([v isKindOfClass:[UITableView class]]) return (UITableView *)v;
    for (UIView *s in v.subviews) {
        UITableView *t = SBAppFindTable(s);
        if (t) return t;
    }
    return nil;
}

static void SBAppCell(char *out, size_t outLen) {
    out[0] = 0;
    dispatch_sync(dispatch_get_main_queue(), ^{
        @try {
            UIWindow *w = SBAppKeyWindow();
            if (!w) { snprintf(out, outLen, "CL nowin"); return; }
            UITableView *t = SBAppFindTable(w);
            if (!t) { snprintf(out, outLen, "CL notable"); return; }

            // 0.0.15：实测 sec=3 而 section 0 是 0 行（置顶/服务区），
            // 直接取 (0,0) 会拿到空位。改为找第一个真正有行的分区。
            NSInteger secs = [t numberOfSections];
            NSInteger ts = -1, rows = 0;
            for (NSInteger i = 0; i < secs; i++) {
                NSInteger r = [t numberOfRowsInSection:i];
                if (r > 0) { ts = i; rows = r; break; }
            }
            if (ts < 0) {
                snprintf(out, outLen, "CL empty secs=%ld vc=%s",
                         (long)secs, [SBAppTopVCName() UTF8String]);
                return;
            }

            NSIndexPath *ip = [NSIndexPath indexPathForRow:0 inSection:ts];
            UITableViewCell *cell = [t cellForRowAtIndexPath:ip];
            NSString *cellCls = cell ? NSStringFromClass([cell class]) : @"nil";

            // didSelect 不要求 cell 已经渲染出来，按 indexPath 直接调就行
            int did = 0;
            id d = [t delegate];
            if (d && [d respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) {
                [t selectRowAtIndexPath:ip animated:NO scrollPosition:UITableViewScrollPositionNone];
                ((void (*)(id, SEL, id, id))objc_msgSend)(d,
                    sel_registerName("tableView:didSelectRowAtIndexPath:"), t, ip);
                did = 1;
            }
            NSString *vc = SBAppTopVCName();
            snprintf(out, outLen, "CL t=%s sec=%ld ts=%ld rows=%ld cell=%s did=%d vc=%s",
                     [NSStringFromClass([t class]) UTF8String],
                     (long)secs, (long)ts, (long)rows,
                     [cellCls UTF8String], did, [vc UTF8String]);
        } @catch (NSException *e) { snprintf(out, outLen, "CL exc"); }
    });
    AL("CELL %s", out);
}

// ===== 0.0.16：真实触摸注入 =====
// 核心差异：不做跨进程投递。在本进程拿自己的 keyWindow._contextId，
// 用 BKSHIDEventSetDigitizerInfo 把事件绑到这个窗口，再 _enqueueHIDEvent:
// 直接塞进本进程事件队列 —— 等于 App 自己收到一次"真手指"。
#define SBTCH_SENDERID 0xDEFACEDBEEFFECE5ULL

@interface UIApplication (SBPrivEnqueue)
- (void)_enqueueHIDEvent:(IOHIDEventRef)ev;
@end
@interface UIWindow (SBPrivCtx)
- (unsigned)_contextId;
@end

static IOHIDEventSystemClientRef g_hidClient = NULL;
static unsigned   g_hidCid   = 0;
static void      *g_bsHandle = NULL;
static int        g_hidReady = 0;

static void SBHidEnsure(UIWindow *w) {
    if (g_hidReady) return;
    @try {
        if ([w respondsToSelector:@selector(_contextId)]) g_hidCid = [w _contextId];
    } @catch (NSException *e) { g_hidCid = 0; }
    g_hidClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!g_bsHandle)
        g_bsHandle = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_NOW);
    g_hidReady = 1;
}

// kind: 0=up 1=down 2=move
static void SBHidPost(int kind, float x, float y) {
    uint64_t ts = mach_absolute_time();
    Boolean isTouch = (kind == 0) ? 0 : 1;
    uint32_t mask = (kind == 2) ? (uint32_t)kIOHIDDigitizerEventPosition
                                : (uint32_t)(kIOHIDDigitizerEventTouch | kIOHIDDigitizerEventRange);

    IOHIDEventRef parent = IOHIDEventCreateDigitizerEvent(kCFAllocatorDefault, ts,
        kIOHIDDigitizerTransducerTypeHand, 0, 0, kIOHIDDigitizerEventTouch, 0,
        0.0, 0.0, 0.0, 0.0, 0.0, 0, true, 0);
    if (!parent) return;
    IOHIDEventSetIntegerValue(parent, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);

    IOHIDEventRef child = IOHIDEventCreateDigitizerFingerEvent(kCFAllocatorDefault, ts,
        1, 3, mask, x, y, 0.0, 0.0, 0.0, isTouch, isTouch, 0);
    if (child) {
        IOHIDEventSetFloatValue(child, kIOHIDEventFieldDigitizerMajorRadius, 0.04f);
        IOHIDEventSetFloatValue(child, kIOHIDEventFieldDigitizerMinorRadius, 0.04f);
        IOHIDEventAppendEvent(parent, child);
        CFRelease(child);
    }
    IOHIDEventSetIntegerValue(parent, kIOHIDEventFieldDigitizerTiltX, kIOHIDDigitizerTransducerTypeHand);
    IOHIDEventSetIntegerValue(parent, kIOHIDEventFieldDigitizerTiltY, 1);
    IOHIDEventSetIntegerValue(parent, kIOHIDEventFieldDigitizerAltitude, 1);

    if (g_bsHandle) {
        typedef void (*FixKind)(IOHIDEventRef, uint32_t, uint8_t, uint8_t, CFStringRef, CFTimeInterval, float);
        FixKind fix = (FixKind)dlsym(g_bsHandle, "BKSHIDEventSetDigitizerInfo");
        if (fix) fix(parent, g_hidCid, 0, 0, NULL, 0.0, 0.0f);
    }

    UIApplication *app = [UIApplication sharedApplication];
    if ([app respondsToSelector:@selector(_enqueueHIDEvent:)]) [app _enqueueHIDEvent:parent];

    IOHIDEventSetSenderID(parent, SBTCH_SENDERID);
    if (g_hidClient) IOHIDEventSystemClientDispatchEvent(g_hidClient, parent);
    CFRelease(parent);
}

static void SBAppTouchXY(float x, float y, char *out, size_t outLen) {
    out[0] = 0;
    dispatch_sync(dispatch_get_main_queue(), ^{
        @try {
            UIWindow *w = SBAppKeyWindow();
            if (!w) { snprintf(out, outLen, "TCH nowin"); return; }
            SBHidEnsure(w);
            SBHidPost(1, x, y);
            usleep(60 * 1000);
            SBHidPost(0, x, y);
            snprintf(out, outLen, "TCH tap %.0f,%.0f cid=%u enq=%d vc=%s",
                     x, y, g_hidCid,
                     [[UIApplication sharedApplication] respondsToSelector:@selector(_enqueueHIDEvent:)] ? 1 : 0,
                     [SBAppTopVCName() UTF8String]);
        } @catch (NSException *e) { snprintf(out, outLen, "TCH exc"); }
    });
    AL("TOUCH %s", out);
}

// 0.0.17：把「找控件」和「真触摸」合一。
// 先按文字在视图树里找，取它在窗口坐标系里的矩形，再用真触摸点它的中心。
// 这样自绘控件（WCSearchBar 这种不是 UIControl、accessibilityActivate 无效的）也能点开。
static void SBAppCollectRect(UIView *v, const char *kw, NSMutableArray *recs, int *cnt) {
    if (!v || *cnt >= 8) return;
    NSString *t = SBAppTextOf(v);
    if (t) {
        const char *cs = [t UTF8String];
        if (cs && strstr(cs, kw)) {
            CGRect r = [v convertRect:v.bounds toView:nil];
            BOOL clk = [v isKindOfClass:[UIControl class]] || (v.gestureRecognizers.count > 0);
            if (r.size.width > 2 && r.size.height > 2 && r.size.width < 2000 && r.size.height < 2000)
                [recs addObject:@[ @(r.origin.x), @(r.origin.y), @(r.size.width), @(r.size.height), @(clk), v ]];
            (*cnt)++;
        }
    }
    for (UIView *s in v.subviews) {
        if (*cnt >= 8) break;
        SBAppCollectRect(s, kw, recs, cnt);
    }
}

static void SBAppHit(NSString *kw, char *out, size_t outLen) {
    out[0] = 0;
    const char *k = kw ? [kw UTF8String] : "";
    if (!k || !*k) { snprintf(out, outLen, "HIT nokw"); return; }

    dispatch_sync(dispatch_get_main_queue(), ^{
        @try {
            UIWindow *w = SBAppKeyWindow();
            if (!w) { snprintf(out, outLen, "HIT nowin"); return; }
            NSMutableArray *recs = [NSMutableArray array];
            int cnt = 0;
            SBAppCollectRect(w, k, recs, &cnt);
            if (recs.count == 0) { snprintf(out, outLen, "HIT notfound"); return; }

            // 打分：可点的优先，其次面积小的（越具体越是那个按钮）
            NSArray *best = nil;
            double bestScore = 1e18;
            for (NSArray *a in recs) {
                BOOL clk = [a[4] boolValue];
                double area = [a[2] doubleValue] * [a[3] doubleValue];
                double score = area + (clk ? 0.0 : 1e7);
                if (score < bestScore) { bestScore = score; best = a; }
            }

            double cx = [best[0] doubleValue] + [best[2] doubleValue] / 2.0;
            double cy = [best[1] doubleValue] + [best[3] doubleValue] / 2.0;

            SBHidEnsure(w);
            SBHidPost(1, (float)cx, (float)cy);
            usleep(60 * 1000);
            SBHidPost(0, (float)cx, (float)cy);

            NSString *cls = NSStringFromClass([(UIView *)best[5] class]);
            snprintf(out, outLen, "HIT n=%d @%.0f,%.0f cls=%s clk=%d cid=%u vc=%s",
                     cnt, cx, cy, [cls UTF8String], [best[4] boolValue], g_hidCid,
                     [SBAppTopVCName() UTF8String]);
        } @catch (NSException *e) { snprintf(out, outLen, "HIT exc"); }
    });
    AL("HIT %s", out);
}

// 0.0.18：界面快照 —— 让模型"看见"界面。
// 取字段（type/label/rect/clickable）照 WebDriverAgent 的 snapshot 规范，
// 过滤规则照 FLEX：hidden / alpha≈0 / 与窗口无交集 / 过小的空壳一律不进。
// 输出按 y（再 x）排序，最多 12 行，一行一个可感知元素。
static NSString *SBAppSnapText(UIView *v) {
    @try {
        NSString *l = nil;
        if ([v respondsToSelector:@selector(accessibilityLabel)]) {
            id x = [v accessibilityLabel];
            if ([x isKindOfClass:[NSString class]] && [x length]) l = x;
        }
        if (!l.length && [v isKindOfClass:[UILabel class]]) {
            NSString *t = [(UILabel *)v text]; if (t.length) l = t;
        }
        if (!l.length && [v isKindOfClass:[UIButton class]]) {
            NSString *t = [(UIButton *)v currentTitle]; if (t.length) l = t;
        }
        if (!l.length && [v isKindOfClass:[UITextField class]]) {
            NSString *t = [(UITextField *)v text];
            if (!t.length) t = [(UITextField *)v placeholder];
            if (t.length) l = t;
        }
        if (!l.length && [v isKindOfClass:[UITextView class]]) {
            NSString *t = [(UITextView *)v text]; if (t.length) l = t;
        }
        if (!l.length && [v respondsToSelector:@selector(accessibilityValue)]) {
            id x = [v accessibilityValue];
            if ([x isKindOfClass:[NSString class]] && [x length]) l = x;
        }
        if (l.length) {
            l = [l stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
            if (l.length > 18) l = [l substringToIndex:18];
        }
        return l;
    } @catch (NSException *e) {}
    return nil;
}

static void SBAppSnapCollect(UIView *v, UIView *win, int widx, NSMutableArray *acc, int *cnt) {
    if (!v || *cnt >= 80) return;
    @try {
        if (!v.hidden && v.alpha >= 0.01) {
            CGRect r = [v convertRect:v.bounds toView:win];
            r.origin.x += win.frame.origin.x;
            r.origin.y += win.frame.origin.y;
            CGRect vis = CGRectIntersection(r, win.bounds);
            NSString *cls = NSStringFromClass([v class]);
            // 0.0.22：过滤放宽 —— 原来把 UIScrollView 当壳，直接把 WCSearchBar 误伤了；
            // 满屏容器也不再在这里砍，改到输出阶段按类别处理。
            BOOL isList = [v isKindOfClass:[UITableView class]] || [v isKindOfClass:[UICollectionView class]];
            BOOL isShell = [cls rangeOfString:@"ContentView"].location != NSNotFound ||
                           [v isKindOfClass:[UIWindow class]];
            if (vis.size.width >= 12 && vis.size.height >= 10 && !isList && !isShell) {
                NSString *txt = SBAppSnapText(v);
                BOOL clk = [v isKindOfClass:[UIControl class]] ||
                           [v isKindOfClass:[UITableViewCell class]] ||
                           (v.gestureRecognizers.count > 0);
                if (txt.length || clk) {
                    [acc addObject:@[ @(r.origin.x), @(r.origin.y), @(r.size.width), @(r.size.height),
                                      cls, txt ? txt : @"", @(clk), @(widx) ]];
                    (*cnt)++;
                }
            }
        }
    } @catch (NSException *e) {}
    for (UIView *s in v.subviews) {
        if (*cnt >= 80) break;
        SBAppSnapCollect(s, win, widx, acc, cnt);
    }
}

// 0.0.21：把根从「一个 keyWindow」扩到「所有 window」。
// 微信的搜索栏 / 底部 tab 有可能是独立的覆盖层窗口，只取 keyWindow 就永远看不见它们。
static NSArray *SBAppAllWindows(void) {
    NSMutableArray *arr = [NSMutableArray array];
    @try {
        UIApplication *app = [UIApplication sharedApplication];
        if (@available(iOS 13.0, *)) {
            for (UIScene *sc in app.connectedScenes) {
                if (![sc isKindOfClass:[UIWindowScene class]]) continue;
                for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                    if (w && ![arr containsObject:w] && w.windowLevel < 2000) [arr addObject:w];
                }
            }
        }
        for (UIWindow *w in app.windows) {
            if (w && ![arr containsObject:w] && w.windowLevel < 2000) [arr addObject:w];
        }
    } @catch (NSException *e) {}
    return arr;
}

// 按类名关键词在树里找第一个命中（用于定向抓搜索栏 / tab 栏容器）
static UIView *SBAppFindClsKey(UIView *v, NSString *key, int depth) {
    if (!v || depth > 24) return nil;
    if ([(NSString *)NSStringFromClass([v class]) rangeOfString:key].location != NSNotFound) return v;
    for (UIView *s in v.subviews) {
        UIView *r = SBAppFindClsKey(s, key, depth + 1);
        if (r) return r;
    }
    return nil;
}

// 收集 tab 栏里的按钮（UITabBarButton 是 UIControl）
static void SBAppCollectBtns(UIView *v, NSMutableArray *out, int depth) {
    if (!v || depth > 3 || out.count >= 6) return;
    NSString *cls = NSStringFromClass([v class]);
    if ([v isKindOfClass:[UIControl class]] ||
        [cls rangeOfString:@"TabBarButton"].location != NSNotFound) {
        [out addObject:v];
        return;
    }
    for (UIView *s in v.subviews) SBAppCollectBtns(s, out, depth + 1);
}

// 0.0.25：这一点到底能不能点到？
// 只看 rect 不够 —— 聊天页会把 tab 栏整条盖住，坐标算出来还是"合法"的，但点下去落到输入栏上。
// 用窗口自己做 hitTest，命中的是不是它自己（或它的子孙）才算真可点。
static BOOL SBAppHittable(UIView *v, UIWindow *w) {
    if (!v || !w) return NO;
    CGPoint c = [v convertPoint:CGPointMake(v.bounds.size.width / 2.0, v.bounds.size.height / 2.0) toView:w];
    if (c.x < 0 || c.y < 0 || c.x > w.bounds.size.width || c.y > w.bounds.size.height) return NO;
    UIView *hit = [w hitTest:c withEvent:nil];
    if (!hit) return NO;
    for (UIView *p = hit; p; p = p.superview) if (p == v) return YES;
    return NO;
}

static void SBAppTree(char *out, size_t outLen) {
    out[0] = 0;
    dispatch_sync(dispatch_get_main_queue(), ^{
        @try {
            NSArray *wins = SBAppAllWindows();
            if (wins.count == 0) { snprintf(out, outLen, "TR nowin"); return; }
            NSMutableArray *acc = [NSMutableArray array];
            int cnt = 0;
            int wi = 0;
            for (UIWindow *w in wins) {
                if (wi >= 4) break;
                SBAppSnapCollect(w, w, wi, acc, &cnt);
                wi++;
            }

            [acc sortUsingComparator:^(id a, id b) {
                double ay = [a[1] doubleValue], by = [b[1] doubleValue];
                if (ay != by) return (ay < by) ? NSOrderedAscending : NSOrderedDescending;
                double ax = [a[0] doubleValue], bx = [b[0] doubleValue];
                return (ax < bx) ? NSOrderedAscending : NSOrderedDescending;
            }];

            // 0.0.22：按语义取样，不再"按 y 分层"。
            // 两次扫漏的教训：WCSearchBar 被「UIScrollView 算壳」误伤、UITabBarButton
            // 被 y 反向取样挤掉。所以直接按容器抓：搜索栏 → tab 按钮 → 会话 cell → 其余。
            UIWindow *w0 = [wins firstObject];
            NSMutableString *ms = [NSMutableString string];
            int line = 0;

            // ① 搜索栏：操作入口，不管有没有文字都必须出现
            UIView *sbv = SBAppFindClsKey(w0, @"SearchBar", 0);
            if (sbv) {
                CGRect r = [sbv convertRect:sbv.bounds toView:nil];
                NSString *t = SBAppSnapText(sbv);
                if (!t.length) {
                    UIView *tfv = SBAppFindClsKey(sbv, @"TextField", 0);
                    if (tfv) t = SBAppSnapText(tfv);
                }
                if (!t.length) {
                    UIView *lab = SBAppFindClsKey(sbv, @"Label", 0);
                    if (lab) t = SBAppSnapText(lab);
                }
                // 输入框 placeholder 是绘图画的、取不到文字，就用语义名兜底：
                // 模型需要的是一个能指的"词"，不是真实像素文字。
                if (!t.length) t = @"搜索";
                line++;
                char flag = SBAppHittable(sbv, w0) ? 'c' : 'x';
                [ms appendFormat:@"%d @bar %@|%.0f,%.0f,%.0fx%.0f|%@|%c\n", line,
                    NSStringFromClass([sbv class]), r.origin.x, r.origin.y, r.size.width, r.size.height,
                    t.length ? t : @"-", flag];
            }

            // ② tab 栏的每个按钮
            UIView *tbv = SBAppFindClsKey(w0, @"TabBar", 0);
            if (tbv) {
                NSMutableArray *btns = [NSMutableArray array];
                SBAppCollectBtns(tbv, btns, 0);
                // 递归收集顺序 ≠ 视觉顺序（实测 x=2 的那个排到最后）。按 x 从小到大排，
                // 才能保证 i=0..3 就是 微信/通讯录/发现/我。
                [btns sortUsingComparator:^(id a, id b) {
                    CGFloat ax = ((UIView *)a).frame.origin.x;
                    CGFloat bx = ((UIView *)b).frame.origin.x;
                    return (ax < bx) ? NSOrderedAscending : NSOrderedDescending;
                }];
                // 微信 tab 文字是画上去的（没有 accessibilityLabel），只能按固定顺序补名。
                // 微信 tab 顺序固定：微信 / 通讯录 / 发现 / 我。
                NSArray *tabNames = @[@"微信", @"通讯录", @"发现", @"我"];
                int ti = 0;
                for (UIView *b in btns) {
                    if (line >= 5) break;
                    CGRect r = [b convertRect:b.bounds toView:nil];
                    NSString *t = SBAppSnapText(b);
                    if (!t.length) {
                        UIView *lab = SBAppFindClsKey(b, @"Label", 0);
                        if (lab) t = SBAppSnapText(lab);
                    }
                    if (!t.length) {
                        t = (btns.count == 4 && ti < 4) ? tabNames[ti] : [NSString stringWithFormat:@"tab%d", ti];
                    }
                    ti++;
                    line++;
                    char flag = SBAppHittable(b, w0) ? 'c' : 'x';
                    [ms appendFormat:@"%d @tab %@|%.0f,%.0f,%.0fx%.0f|%@|%c\n", line,
                        NSStringFromClass([b class]), r.origin.x, r.origin.y, r.size.width, r.size.height, t, flag];
                }
            }

            // ③ 会话列表：只取有文字、可点的 cell，最多 4 条
            int got = 0;
            for (NSArray *a in acc) {
                if (line >= 9 || got >= 4) break;
                if ([(NSString *)a[4] rangeOfString:@"Cell"].location == NSNotFound) continue;
                if (![(NSString *)a[5] length] || ![a[6] boolValue]) continue;
                int wi2 = [a[7] intValue];
                UIWindow *wsel = (wi2 >= 0 && wi2 < (int)wins.count) ? wins[wi2] : w0;
                // 行本身拿不到对象指针，就用"这一点命中的东西是不是某个 Cell 的后代"来判定
                CGPoint cp = CGPointMake([a[0] doubleValue] + [a[2] doubleValue] / 2.0,
                                         [a[1] doubleValue] + [a[3] doubleValue] / 2.0);
                UIView *hit = [wsel hitTest:cp withEvent:nil];
                BOOL hb = NO;
                for (UIView *pv = hit; pv; pv = pv.superview) {
                    if ([(NSString *)NSStringFromClass([pv class]) rangeOfString:@"Cell"].location != NSNotFound) { hb = YES; break; }
                }
                got++;
                line++;
                [ms appendFormat:@"%d @list w%d %@|%.0f,%.0f,%.0fx%.0f|%@|%c\n", line, [a[7] intValue],
                    a[4], [a[0] doubleValue], [a[1] doubleValue],
                    [a[2] doubleValue], [a[3] doubleValue], a[5], hb ? 'c' : 'x'];
            }

            // ④ 其余有文字的元素，补满 12 行（满屏容器一律不要）
            int o = 0;
            for (NSArray *a in acc) {
                if (line >= 12 || o >= 3) break;
                NSString *cls = (NSString *)a[4];
                if ([cls rangeOfString:@"Cell"].location != NSNotFound) continue;
                if ([cls rangeOfString:@"TabBar"].location != NSNotFound) continue;
                if ([cls rangeOfString:@"SearchBar"].location != NSNotFound) continue;
                if (![(NSString *)a[5] length]) continue;
                double ar = [a[2] doubleValue] * [a[3] doubleValue];
                if (ar > 260000) continue;
                o++;
                line++;
                [ms appendFormat:@"%d @el w%d %@|%.0f,%.0f,%.0fx%.0f|%@\n", line, [a[7] intValue],
                    a[4], [a[0] doubleValue], [a[1] doubleValue],
                    [a[2] doubleValue], [a[3] doubleValue], a[5]];
            }

            // 完整快照落文件：日志单条 768 字节，12 行中文必被切，这里不留遗憾
            NSString *full = [NSString stringWithFormat:@"TR n=%d/%d vc=%@\n%@", line, cnt,
                              SBAppTopVCName(), ms];
            const char *home = getenv("HOME");
            if (home && *home) {
                char tp[512];
                snprintf(tp, sizeof tp, "%s/Documents/sb.tree", home);
                FILE *tf = fopen(tp, "w");
                if (tf) { fputs([full UTF8String], tf); fclose(tf); }
            }

            if (ms.length > (NSUInteger)(outLen - 60)) ms = (NSMutableString *)[ms substringToIndex:outLen - 60];
            snprintf(out, outLen, "TR n=%d/%d vc=%s\n%s", line, cnt,
                     [SBAppTopVCName() UTF8String], [ms UTF8String]);
        } @catch (NSException *e) { snprintf(out, outLen, "TR exc"); }
    });
    AL("TREE %s", out);
}

// 0.0.21：定向探测 —— 搜类名含 TabBar / SearchBar 的容器，
// 连同它下面第一层子元素的文字和坐标一起打出来。
// 目的：确认微信的搜索栏 / 底部 tab 到底挂在哪个 window 的哪一层。
static void SBAppProbeWalk(UIView *v, UIView *win, int widx, int depth, NSMutableArray *acc, int *cnt) {
    if (!v || *cnt >= 8 || depth > 14) return;
    @try {
        NSString *cls = NSStringFromClass([v class]);
        BOOL hit = ([cls rangeOfString:@"TabBar"].location != NSNotFound) ||
                   ([cls rangeOfString:@"Tabbar"].location != NSNotFound) ||
                   ([cls rangeOfString:@"SearchBar"].location != NSNotFound) ||
                   ([cls rangeOfString:@"Searchbar"].location != NSNotFound) ||
                   ([cls rangeOfString:@"TabBarController"].location != NSNotFound);
        if (hit) {
            CGRect r = [v convertRect:v.bounds toView:win];
            r.origin.x += win.frame.origin.x;
            r.origin.y += win.frame.origin.y;
            NSString *line = [NSString stringWithFormat:@"C w%d %@|%.0f,%.0f,%.0fx%.0f",
                              widx, cls, r.origin.x, r.origin.y, r.size.width, r.size.height];
            [acc addObject:line];
            (*cnt)++;
            int k = 0;
            for (UIView *s in v.subviews) {
                if (k >= 5) break;
                k++;
                NSString *t = SBAppSnapText(s);
                CGRect sr = [s convertRect:s.bounds toView:win];
                sr.origin.x += win.frame.origin.x;
                sr.origin.y += win.frame.origin.y;
                [acc addObject:[NSString stringWithFormat:@"  - %@|%.0f,%.0f|%@",
                                NSStringFromClass([s class]), sr.origin.x, sr.origin.y,
                                t.length ? t : @"-"]];
            }
        }
    } @catch (NSException *e) {}
    for (UIView *s in v.subviews) {
        if (*cnt >= 8) break;
        SBAppProbeWalk(s, win, widx, depth + 1, acc, cnt);
    }
}

static void SBAppProbe(char *out, size_t outLen) {
    out[0] = 0;
    dispatch_sync(dispatch_get_main_queue(), ^{
        @try {
            NSArray *wins = SBAppAllWindows();
            NSMutableArray *lines = [NSMutableArray array];
            int cnt = 0, wi = 0;
            for (UIWindow *w in wins) {
                if (wi >= 4 || cnt >= 8) break;
                [lines addObject:[NSString stringWithFormat:@"W%d %@|%.0fx%.0f lv=%.0f",
                    wi, NSStringFromClass([w class]), w.bounds.size.width, w.bounds.size.height,
                    (double)w.windowLevel]];
                SBAppProbeWalk(w, w, wi, 0, lines, &cnt);
                wi++;
            }
            NSMutableString *ms = [NSMutableString stringWithString:[lines componentsJoinedByString:@"\n"]];
            if (ms.length > (NSUInteger)(outLen - 30)) [ms setString:[ms substringToIndex:outLen - 30]];
            snprintf(out, outLen, "PB n=%d\n%s", cnt, [ms UTF8String]);
        } @catch (NSException *e) { snprintf(out, outLen, "PB exc"); }
    });
    AL("PROBE %s", out);
}

static void SBAppDragXY(float x1, float y1, float x2, float y2, char *out, size_t outLen) {
    out[0] = 0;
    dispatch_sync(dispatch_get_main_queue(), ^{
        @try {
            UIWindow *w = SBAppKeyWindow();
            if (!w) { snprintf(out, outLen, "DRG nowin"); return; }
            SBHidEnsure(w);
            SBHidPost(1, x1, y1);
            for (int i = 1; i <= 10; i++) {
                float t = (float)i / 10.0f;
                SBHidPost(2, x1 + (x2 - x1) * t, y1 + (y2 - y1) * t);
                usleep(18 * 1000);
            }
            SBHidPost(0, x2, y2);
            snprintf(out, outLen, "DRG %.0f,%.0f -> %.0f,%.0f cid=%u vc=%s",
                     x1, y1, x2, y2, g_hidCid, [SBAppTopVCName() UTF8String]);
        } @catch (NSException *e) { snprintf(out, outLen, "DRG exc"); }
    });
    AL("DRAG %s", out);
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
    } else if (!strcmp(cmd, "cell")) {
        @autoreleasepool { SBAppCell(out, outLen); }
    } else if (!strcmp(cmd, "tree")) {
        @autoreleasepool { SBAppTree(out, outLen); }
    } else if (!strcmp(cmd, "probe")) {
        @autoreleasepool { SBAppProbe(out, outLen); }
    } else if (!strncmp(cmd, "hit:", 4)) {
        NSString *kw = [NSString stringWithUTF8String:cmd + 4];
        @autoreleasepool { SBAppHit(kw, out, outLen); }
    } else if (!strncmp(cmd, "touch:", 6)) {
        float x = 0, y = 0;
        sscanf(cmd + 6, "%f,%f", &x, &y);
        @autoreleasepool { SBAppTouchXY(x, y, out, outLen); }
    } else if (!strncmp(cmd, "drag:", 5)) {
        float a = 0, b = 0, c = 0, d = 0;
        sscanf(cmd + 5, "%f,%f,%f,%f", &a, &b, &c, &d);
        @autoreleasepool { SBAppDragXY(a, b, c, d, out, outLen); }
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
