#import "SiriBridge.h"
#include <string.h>

//  观察 + 按 SiriPlus 机制吞掉原生回答：
//  原生渲染入口是 -[AFConnection pushResponseWithText:] 与 -[AFConnection preSynthTTSWithText:]，
//  SiriPlus 对这两条 addMethod 且整条不转发，再补自己的 ACE。这里照做，但只在 AI 在途时吞，
//  原生路由的请求仍走 orig（保留兜底）。

static IMP g_obsCmd = NULL;
static IMP g_obsTimeout = NULL;
static IMP g_obsDisappear = NULL;
static IMP g_obsPush = NULL;
static IMP g_obsPreTTS = NULL;

static void sbObsCmd(id self, SEL _cmd, id cmd, id reply) {
    const char *cn = cmd ? class_getName(object_getClass(cmd)) : "(nil)";
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
    SBLogSync("OBS viewWillDisappear %d", (int)animated);
    if (g_obsDisappear) ((void (*)(id, SEL, BOOL))g_obsDisappear)(self, _cmd, animated);
}

static void sbSwallowPush(id self, SEL _cmd, id text) {
    if (SBAIPending()) { SBLogSync("SWALLOW pushResponseWithText"); return; }
    SBLogSync("OBS pushResponseWithText pass");
    if (g_obsPush) ((void (*)(id, SEL, id))g_obsPush)(self, _cmd, text);
}

static void sbSwallowPreTTS(id self, SEL _cmd, id text) {
    if (SBAIPending()) { SBLogSync("SWALLOW preSynthTTS"); return; }
    SBLogSync("OBS preSynthTTS pass");
    if (g_obsPreTTS) ((void (*)(id, SEL, id))g_obsPreTTS)(self, _cmd, text);
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
    Class del = objc_getClass("AFConnectionClientServiceDelegate");
    sbObsHook(conn, "_handleCommand:reply:", (IMP)sbObsCmd, &g_obsCmd, "cmd");
    sbObsHook(conn, "_invokeRequestTimeoutForReason:", (IMP)sbObsTimeout, &g_obsTimeout, "timeout");
    Class ui = objc_getClass("AFUISiriViewController");
    sbObsHook(ui, "viewWillDisappear:", (IMP)sbObsDisappear, &g_obsDisappear, "disappear");

    // 原生回答的两个渲染入口：优先 AFConnection，不在则试 delegate
    if (conn && class_getInstanceMethod(conn, sel_registerName("pushResponseWithText:"))) {
        sbObsHook(conn, "pushResponseWithText:", (IMP)sbSwallowPush, &g_obsPush, "push");
        sbObsHook(conn, "preSynthTTSWithText:", (IMP)sbSwallowPreTTS, &g_obsPreTTS, "pretts");
    } else {
        SBLogSync("OBS push on delegate");
        sbObsHook(del, "pushResponseWithText:", (IMP)sbSwallowPush, &g_obsPush, "push");
        sbObsHook(del, "preSynthTTSWithText:", (IMP)sbSwallowPreTTS, &g_obsPreTTS, "pretts");
    }
}
