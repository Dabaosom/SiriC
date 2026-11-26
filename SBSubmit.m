#import "SiriBridge.h"

//  L5：纯 C 实现，不定义任何 ObjC 类（避免 __objc_classlist 在 RootHide 补丁链上出问题）。
//  保存原 IMP，主队列，空 block，重入锁，异常包裹。

static IMP g_orig = NULL;
static BOOL g_submitting = NO;

static void sbPass(id self, SEL _cmd, id cmd, id reply) {
    if (g_orig) ((void (*)(id, SEL, id, id))g_orig)(self, _cmd, cmd, reply);
}

BOOL SBSubmitInstall(void) {
    Class cls = objc_getClass("AFConnection");
    if (!cls) return NO;
    Method m = class_getInstanceMethod(cls, sel_registerName("_handleCommand:reply:"));
    if (!m) return NO;
    g_orig = method_getImplementation(m);
    method_setImplementation(m, (IMP)sbPass);
    SBLog(@"SUBMIT orig=%p", g_orig);
    return YES;
}

BOOL SBSubmitAce(id ace, id conn) {
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
