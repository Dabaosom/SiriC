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

typedef struct { id ace; id conn; int isTTS; int noFlush; } SBSubJob;

static void sbSubmitRun(void *p) {
    SBSubJob *j = (SBSubJob *)p;
    @try {
        void *reply = SBMakeNoopBlock();
        SBLog("SUBMIT call %s reply=%p", j->isTTS ? "tts" : "addviews", reply);
        ((void (*)(id, SEL, id, id))g_orig)(j->conn,
            sel_registerName("_handleCommand:reply:"), j->ace, reply);
        SBLogSync("SUBMIT ok %s", j->isTTS ? "tts" : "addviews");
        // 1.5.4：回答已进原生管线，这时才把原生那条命令的回执补上，收掉这一轮。
        // 1.6.11：流式首句走 noFlush，只上屏+说话，不结账，回执照旧挂着。
        if (!j->isTTS && !j->noFlush) SBFlushHeldReply();
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

static BOOL sbSubmitInternal(id ace, id conn, int noFlush) {
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
    j->noFlush = noFlush;

    // 提交入口：直接在当前线程（网络回调线程）执行。
    // 绕回主队列再调 _handleCommand:reply: 会与该方法的内部同步互锁。
    g_submitting = YES;
    sbSubmitRun(j);
    return YES;
}

BOOL SBSubmitAce(id ace, id conn) { return sbSubmitInternal(ace, conn, 0); }

// 1.6.11：流式首句用这个 —— 上屏并合成，但不放行原生回执，这一轮继续在途。
BOOL SBSubmitAceNoFlush(id ace, id conn) { return sbSubmitInternal(ace, conn, 1); }
