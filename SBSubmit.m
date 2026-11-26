#import "SiriBridge.h"

//  L5：保存原 IMP，主队列，空 block。纯 C 模块，不定义 ObjC 类。

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
    SBLog("SUBMIT orig=%p", (void *)g_orig);
    return YES;
}

typedef struct { id ace; id conn; int isTTS; } SBSubJob;

static void sbSubmitRun(void *p) {
    SBSubJob *j = (SBSubJob *)p;
    @try {
        void (^empty)(void) = ^{};
        ((void (*)(id, SEL, id, id))g_orig)(j->conn,
            sel_registerName("_handleCommand:reply:"), j->ace, (id)empty);
        SBLog("SUBMIT ok %s", j->isTTS ? "tts" : "addviews");
    } @catch (id e) {
        const char *n = e ? (const char *)SBMsgC(e, "name") : NULL;
        (void)n;
        SBLog("SUBMIT exception");
    } @finally {
        g_submitting = NO;
        SBMsgC(j->ace, "release");
        SBMsgC(j->conn, "release");
        free(j);
    }
}

BOOL SBSubmitAce(id ace, id conn) {
    if (!g_orig || !ace || !conn) return NO;
    if (g_submitting) { SBLog("SUBMIT reentrant"); return NO; }

    if (!SBClassIs(ace, "SAUIAddViews") && !SBClassIs(ace, "SAPreSynthesizeTTS")) {
        SBLog("SUBMIT bad class");
        return NO;
    }

    SBSubJob *j = calloc(1, sizeof(SBSubJob));
    if (!j) return NO;
    j->ace = SBMsgC(ace, "retain");
    j->conn = SBMsgC(conn, "retain");
    j->isTTS = SBClassIs(ace, "SAPreSynthesizeTTS") ? 1 : 0;

    // 照逆向：主队列异步 + orig IMP + 空 block
    g_submitting = YES;
    dispatch_async_f(dispatch_get_main_queue(), j, sbSubmitRun);
    return YES;
}
