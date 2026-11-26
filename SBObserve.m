#import "SiriBridge.h"
#include <string.h>
#include <stdlib.h>
#include <unistd.h>

//  观察 + AI 在途期间的会话保持。
//  注：pushResponseWithText: / preSynthTTSWithText: 在本机 AFConnection 与 delegate 上均不存在，
//  全类扫描匹配到无关类并导致 SIGABRT，已废弃。这里只在命令层压原生回答，不调用原生 reply。

static IMP g_obsCmd = NULL;
static IMP g_obsTimeout = NULL;
static IMP g_obsDisappear = NULL;

static void sbObsCmd(id self, SEL _cmd, id cmd, id reply) {
    const char *cn = cmd ? class_getName(object_getClass(cmd)) : "(nil)";
    if (SBAIPending() && cn &&
        (!strcmp(cn, "SAUIAddViews") || !strcmp(cn, "SAPreSynthesizeTTS"))) {
        SBLogSync("OBS drop %s", cn);
        return;   // 不转发、不调用原生 reply
    }
    SBLogSync("OBS cmd %s", cn);
    if (g_obsCmd) ((void (*)(id, SEL, id, id))g_obsCmd)(self, _cmd, cmd, reply);
}

static void sbObsTimeout(id self, SEL _cmd, id reason) {
    if (SBAIPending()) { SBLogSync("OBS hold timeout"); return; }
    if (reason && SBHasSelC(reason, "UTF8String")) {
        const char *s = (const char *)SBMsgC(reason, "UTF8String");
        if (s) SBLogSync("OBS timeout %s", s);
    }
    if (g_obsTimeout) ((void (*)(id, SEL, id))g_obsTimeout)(self, _cmd, reason);
}

static void sbObsDisappear(id self, SEL _cmd, BOOL animated) {
    if (SBAIPending()) { SBLogSync("OBS hold disappear"); return; }
    SBLogSync("OBS viewWillDisappear %d", (int)animated);
    if (g_obsDisappear) ((void (*)(id, SEL, BOOL))g_obsDisappear)(self, _cmd, animated);
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
    Class ui = objc_getClass("AFUISiriViewController");
    sbObsHook(ui, "viewWillDisappear:", (IMP)sbObsDisappear, &g_obsDisappear, "disappear");
}

// ---- 只读 selftest：把 AFConnection 的方法表摊开，区分「时序 / 进程 / 版本」三类 nil 成因 ----
//  不新增任何方法、不改 IMP、不碰 delegate。
void SBSelfTestDump(const char *tag) {
    Class c = objc_getClass("AFConnection");
    SBLogSync("ST[%s] proc=%s pid=%d cls=%p", tag, getprogname(), (int)getpid(), (void *)c);
    if (!c) { SBLogSync("ST[%s] cls nil", tag); return; }

    unsigned int n = 0;
    Method *ms = class_copyMethodList(c, &n);
    SBLogSync("ST[%s] count=%u", tag, n);

    int hit = 0;
    for (unsigned i = 0; i < n; i++) {
        const char *nm = sel_getName(method_getName(ms[i]));
        if (!nm) continue;
        if (!strncmp(nm, "push", 4) || !strncmp(nm, "preSynth", 8) ||
            !strncmp(nm, "_handle", 7) || !strncmp(nm, "startRequest", 12) ||
            !strncmp(nm, "_tellSpeech", 11) || !strncmp(nm, "response", 8)) {
            SBLog("ST[%s] m=%s", tag, nm);
            hit++;
        }
    }
    free(ms);

    Method p = class_getInstanceMethod(c, sel_registerName("pushResponseWithText:"));
    Method q = class_getInstanceMethod(c, sel_registerName("preSynthTTSWithText:"));
    SBLogSync("ST[%s] hit=%d put=%d pst=%d", tag, hit, p ? 1 : 0, q ? 1 : 0);
}
