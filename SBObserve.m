#import "SiriBridge.h"
#include <string.h>

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
