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
    // 不再 setImplementation：我们自己这层转发会在 AFConnection 内部自调用时叠加，
    // 表现为「调不返回、也不落崩溃报告」。这一版只取 orig，不拦。
    SBLogSync("SUBMIT orig=%p (nohook)", (void *)g_orig);
    return YES;
}

typedef struct { id ace; id conn; int isTTS; } SBSubJob;

static void sbSubmitRun(void *p) {
    SBSubJob *j = (SBSubJob *)p;
    @try {
        void *reply = SBMakeNoopBlock();
        SBLogSync("SUBMIT call %s reply=%p", j->isTTS ? "tts" : "addviews", reply);
        ((void (*)(id, SEL, id, id))g_orig)(j->conn,
            sel_registerName("_handleCommand:reply:"), j->ace, reply);
        SBLogSync("SUBMIT ok %s", j->isTTS ? "tts" : "addviews");
    } @catch (id e) {
        const char *n = e ? (const char *)SBMsgC(e, "name") : NULL;
        (void)n;
        SBLogSync("SUBMIT exception");
    } @finally {
        g_submitting = NO;
        SBMsgC(j->ace, "release");
        SBMsgC(j->conn, "release");
        free(j);
    }
}

BOOL SBSubmitAce(id ace, id conn) {
    // 逆向提醒：原插件提交前走的是 Orion 静态 target，activate 前为 nil，
    // 那种情况下就是「构造 OK、交出去第一跳 SIGSEGV」。这里绑定的是识别回调实参，
    // 所以必须先把这条链路上的 conn 验一遍，nil 直接拒绝。
    const char *cn = conn ? class_getName(object_getClass(conn)) : "(nil)";
    SBLogSync("SUBMIT conn=%p cls=%s", (void *)conn, cn);
    if (!g_orig || !ace || !conn) { SBLogSync("SUBMIT abort nil"); return NO; }
    if (!SBClassIs(conn, "AFConnection")) SBLogSync("SUBMIT conn not AFConnection");
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
