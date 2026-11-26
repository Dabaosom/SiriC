#import "SiriBridge.h"

//  L5：保存原 IMP，主队列，空 block，重入锁，异常包裹。
//  旧版崩点就是 reply=nil + 字段缺失 → NSException → 安全模式。

static IMP g_orig = NULL;
static BOOL g_submitting = NO;

static void sbPass(id self, SEL _cmd, id cmd, id reply) {
    if (g_orig) ((void (*)(id, SEL, id, id))g_orig)(self, _cmd, cmd, reply);
}

@implementation SBSubmitter

+ (BOOL)install {
    Class cls = objc_getClass("AFConnection");
    if (!cls) return NO;
    Method m = class_getInstanceMethod(cls, sel_registerName("_handleCommand:reply:"));
    if (!m) return NO;
    g_orig = method_getImplementation(m);
    method_setImplementation(m, (IMP)sbPass);
    SBLog(@"SUBMIT orig=%p", g_orig);
    return YES;
}

+ (BOOL)submit:(id)ace on:(id)conn {
    if (!g_orig || !ace || !conn) return NO;
    if (g_submitting) { SBLog(@"SUBMIT reentrant"); return NO; }

    NSString *cn = NSStringFromClass(object_getClass(ace));
    if (![cn isEqualToString:@"SAUIAddViews"] &&
        ![cn isEqualToString:@"SAPreSynthesizeTTS"]) {
        SBLog(@"SUBMIT bad class %@", cn);
        return NO;
    }

    __block BOOL ok = NO;
    void (^work)(void) = ^{
        if (g_submitting) return;
        g_submitting = YES;
        @try {
            void (^empty)(void) = ^{};
            ((void (*)(id, SEL, id, id))g_orig)(conn,
                sel_registerName("_handleCommand:reply:"), ace, (id)empty);
            ok = YES;
            SBLog(@"SUBMIT ok %@", cn);
        } @catch (NSException *e) {
            SBLog(@"SUBMIT exception %@: %@", e.name, e.reason);
        } @finally {
            g_submitting = NO;
        }
    };

    if ([NSThread isMainThread]) work();
    else dispatch_sync(dispatch_get_main_queue(), work);
    return ok;
}

@end
