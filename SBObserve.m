#import "SiriBridge.h"
#include <string.h>

//  纯观察：只记录并转发，不改变 Siri 行为。

static IMP g_obsCmd = NULL;
static IMP g_obsTimeout = NULL;
static IMP g_obsDisappear = NULL;

static void sbObsCmd(id self, SEL _cmd, id cmd, id reply) {
    const char *cn = cmd ? class_getName(object_getClass(cmd)) : "(nil)";
    // AI 在途：压住 Siri 原生回答的渲染与朗读，等我们的 ACE。
    // 我们自己的提交走 orig 直调，不经过这里，不受影响。
    if (SBAIPending() && cn &&
        (!strcmp(cn, "SAUIAddViews") || !strcmp(cn, "SAPreSynthesizeTTS"))) {
        SBLogSync("OBS drop %s", cn);
        if (reply) ((void (^)(id))reply)(nil);
        return;
    }
    SBLogSync("OBS cmd %s", cn);
    if (g_obsCmd) ((void (*)(id, SEL, id, id))g_obsCmd)(self, _cmd, cmd, reply);
}

static void sbObsTimeout(id self, SEL _cmd, id reason) {
    if (SBAIPending()) { SBLogSync("OBS hold timeout"); return; }
    const char *cn = reason ? class_getName(object_getClass(reason)) : "(nil)";
    SBLogSync("OBS timeout cls=%s", cn);
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
