#import "SiriBridge.h"
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <dlfcn.h>

//  观察层：1.4.5 起回到“纯观察”，全部转发、不再压任何东西。
//  1.4.2 的三条 hold（丢原生 ACE / 按住超时 / 按住窗口消失）已撤：实测会把 Siri
//  按死在既无事件也不结束的静止态。selftest 已证明本机 AFConnection 上
//  没有 pushResponseWithText: / preSynthTTSWithText:（put=0 pst=0），
//  所以“吞原生回答”不能靠那两条，必须先看原生与自造的时序。

static IMP g_obsCmd = NULL;
static IMP g_obsTimeout = NULL;
static IMP g_obsDisappear = NULL;
static IMP g_obsDidDisappear = NULL;
static IMP g_obsReqEnd = NULL;

static void *g_heldReply = NULL;
static void *(*p_blockCopy)(const void *) = NULL;
static void *(*g_heldRelease)(const void *) = NULL;

// 1.5.4 结账：AI 的 AddViews 提交成功后，用存下的原生 reply 收掉这一轮。
void SBFlushHeldReply(void) {
    void *r = g_heldReply;
    g_heldReply = NULL;
    if (!r) { SBLogSync("OBS held reply none"); return; }
    SBLogSync("OBS held reply flush");
    if (!g_heldRelease) g_heldRelease = (void *(*)(const void *))dlsym(RTLD_DEFAULT, "_Block_release");
    dispatch_async(dispatch_get_main_queue(), ^{
        ((void (^)(id, id))r)(nil, nil);
        if (g_heldRelease) ((void (*)(const void *))g_heldRelease)(r);
        SBLogSync("OBS held reply done");
    });
}

// _requestDidEnd 是「本轮请求结束」的收尾点，void、无回执，按住它不会悬挂任何东西。
static void sbObsReqEnd(id self, SEL _cmd) {
    if (SBAIPending()) { SBLogSync("OBS hold reqEnd"); return; }
    SBLogSync("OBS reqEnd");
    if (g_obsReqEnd) ((void (*)(id, SEL))g_obsReqEnd)(self, _cmd);
}

// 1.5.0 只读探针：读 reply block 的类型签名 + 命令的 dialogPhase。
// 只读，不吞、不调用 reply、不碰原实现。
static const char *(*p_blockSig)(const void *) = NULL;
static int g_sigDone = 0;
static int g_phaseDone = 0;

static void sbProbeReply(id cmd, id reply) {
    if (!g_sigDone) {
        g_sigDone = 1;
        if (!p_blockSig) p_blockSig = (const char *(*)(const void *))dlsym(RTLD_DEFAULT, "_Block_signature");
        const char *sig = (p_blockSig && reply) ? p_blockSig((const void *)reply) : NULL;
        SBLogSync("SIG reply sig=%s", sig ? sig : "(none)");
    }
}

// 只抓 SAUIAddViews 自己的 dialogPhase / aceId（其它命令没有 dialogPhase，抓了也是 nil）
static void sbProbeAddViews(id cmd) {
    if (g_phaseDone || !cmd) return;
    const char *cn = class_getName(object_getClass(cmd));
    if (!cn || strcmp(cn, "SAUIAddViews")) return;
    g_phaseDone = 1;

    id phase = SBHasSelC(cmd, "dialogPhase") ? SBMsgC(cmd, "dialogPhase") : nil;
    const char *ph = "(nil)";
    if (phase && SBHasSelC(phase, "UTF8String")) {
        const char *s = (const char *)SBMsgC(phase, "UTF8String");
        if (s) ph = s;
    }
    id ace = SBHasSelC(cmd, "aceId") ? SBMsgC(cmd, "aceId") : nil;
    const char *ac = (ace && SBHasSelC(ace, "UTF8String")) ? (const char *)SBMsgC(ace, "UTF8String") : "(nil)";
    SBLogSync("SIG addviews phase=%s", ph);
    SBLogSync("SIG addviews ace=%s", ac ? ac : "(nil)");
}

static void sbObsCmd(id self, SEL _cmd, id cmd, id reply) {
    const char *cn = cmd ? class_getName(object_getClass(cmd)) : "(nil)";
    sbProbeReply(cmd, reply);
    sbProbeAddViews(cmd);

    // AI 在途时：原生最终回答/合成一律不进原实现。
    // 1.5.4：SAUIAddViews 的 reply 不再当场回，改为存起来延后结账 —— 实测「吞+立刻回执」
    // 会让 UI 认为本轮已了结，0.3 秒后 viewWillDisappear；回执挂住则这一轮一直算在途。
    // reply 签名实测 v24@?0@8@16 = void(^)(id, id)，回 (nil, nil) 与参数顺序无关。
    if (SBAIPending() && cn &&
        (!strcmp(cn, "SAUIAddViews") || !strcmp(cn, "SAPreSynthesizeTTS"))) {
        SBLogSync("OBS swallow %s", cn);
        if (reply && !strcmp(cn, "SAUIAddViews")) {
            // 只留最后一条（多相位时以后的为准），旧的直接放行结掉，避免堆积悬挂。
            if (g_heldReply) {
                SBLogSync("OBS held reply replace");
                ((void (^)(id, id))g_heldReply)(nil, nil);
                if (g_heldRelease) ((void (*)(const void *))g_heldRelease)(g_heldReply);
                g_heldReply = NULL;
            }
            if (!p_blockCopy) p_blockCopy = (void *(*)(const void *))dlsym(RTLD_DEFAULT, "_Block_copy");
            g_heldReply = p_blockCopy ? p_blockCopy(reply) : (void *)reply;
            SBLogSync("OBS held reply save copy=%d", p_blockCopy ? 1 : 0);
            // 1.5.5 兜底：AI 迟迟不回来（或失败路径没走到）时，12 秒后自己放行回执。
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (g_heldReply) {
                    SBLogSync("OBS held reply timeout");
                    SBFlushHeldReply();
                }
            });
        } else if (reply) {
            ((void (^)(id, id))reply)(nil, nil);
            SBLogSync("OBS swallow reply done");
        }
        return;
    }

    SBLogSync("OBS cmd %s pend=%d", cn, SBAIPending() ? 1 : 0);
    if (g_obsCmd) ((void (*)(id, SEL, id, id))g_obsCmd)(self, _cmd, cmd, reply);
}

static void sbObsTimeout(id self, SEL _cmd, id reason) {
    if (reason && SBHasSelC(reason, "UTF8String")) {
        const char *s = (const char *)SBMsgC(reason, "UTF8String");
        if (s) SBLogSync("OBS timeout %s", s);
    } else {
        SBLogSync("OBS timeout (nonstr)");
    }
    if (g_obsTimeout) ((void (*)(id, SEL, id))g_obsTimeout)(self, _cmd, reason);
}

static void sbObsDisappear(id self, SEL _cmd, BOOL animated) {
    SBLogSync("OBS viewWillDisappear %d pend=%d", (int)animated, SBAIPending() ? 1 : 0);
    if (g_obsDisappear) ((void (*)(id, SEL, BOOL))g_obsDisappear)(self, _cmd, animated);
}

static void sbObsDidDisappear(id self, SEL _cmd, BOOL animated) {
    SBLogSync("OBS viewDidDisappear %d", (int)animated);
    if (g_obsDidDisappear) ((void (*)(id, SEL, BOOL))g_obsDidDisappear)(self, _cmd, animated);
}

static void sbObsHook(Class cls, const char *sel, IMP rep, IMP *orig, const char *tag) {
    if (!cls) { SBLogSync("OBS %s noclass", tag); return; }
    Method m = class_getInstanceMethod(cls, sel_registerName(sel));
    if (!m) { SBLogSync("OBS %s nomethod", tag); return; }
    *orig = method_getImplementation(m);
    method_setImplementation(m, rep);
    SBLogSync("OBS %s ok", tag);
}

void SBObserveInstall(void) {
    Class conn = objc_getClass("AFConnection");
    sbObsHook(conn, "_handleCommand:reply:", (IMP)sbObsCmd, &g_obsCmd, "cmd");
    sbObsHook(conn, "_invokeRequestTimeoutForReason:", (IMP)sbObsTimeout, &g_obsTimeout, "timeout");
    sbObsHook(conn, "_requestDidEnd", (IMP)sbObsReqEnd, &g_obsReqEnd, "reqEnd");
    Method mre = class_getInstanceMethod(conn, sel_registerName("_requestDidEnd"));
    if (mre) SBLogSync("OBS reqEnd enc=%s", method_getTypeEncoding(mre));
    Class ui = objc_getClass("AFUISiriViewController");
    sbObsHook(ui, "viewWillDisappear:", (IMP)sbObsDisappear, &g_obsDisappear, "disappear");
    sbObsHook(ui, "viewDidDisappear:", (IMP)sbObsDidDisappear, &g_obsDidDisappear, "diddisappear");
}

// ---- 只读 selftest：把 AFConnection 的完整方法表摊开 ----
//  不新增任何方法、不改 IMP、不碰 delegate。
void SBSelfTestDump(const char *tag) {
    Class c = objc_getClass("AFConnection");
    SBLogSync("ST[%s] proc=%s pid=%d cls=%p", tag, getprogname(), (int)getpid(), (void *)c);
    if (!c) { SBLogSync("ST[%s] cls nil", tag); return; }

    unsigned int n = 0;
    Method *ms = class_copyMethodList(c, &n);
    SBLogSync("ST[%s] count=%u", tag, n);

    for (unsigned i = 0; i < n; i++) {
        const char *nm = sel_getName(method_getName(ms[i]));
        if (!nm) continue;
        SBLog("ST[%s] #%u %s", tag, i, nm);
    }
    free(ms);

    Method p = class_getInstanceMethod(c, sel_registerName("pushResponseWithText:"));
    Method q = class_getInstanceMethod(c, sel_registerName("preSynthTTSWithText:"));
    SBLogSync("ST[%s] put=%d pst=%d", tag, p ? 1 : 0, q ? 1 : 0);
}
