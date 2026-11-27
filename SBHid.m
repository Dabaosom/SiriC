// SBHid.m — 1.6.47
// SpringBoard 侧 HID 投递能力探测。
// 1) 查自己有没有 hid event-dispatch entitlement（SecTask 自查询）
// 2) 用 IOHIDEventSystemClientCreateWithType 的 Admin/Monitor 类型建 client 再投一次
// 全程不 ScheduleWithRunLoop、不 dispatch_sync 主线程（1.6.36 watchdog 的教训）。

#import "SiriBridge.h"
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <mach/mach_time.h>
#import <pthread.h>
#import <stdarg.h>
#import <stdio.h>

static void *HSym(const char *n) { return dlsym(RTLD_DEFAULT, n); }

static void hidEntPrint(void) {
    void *(*mkTask)(CFAllocatorRef) = (void *(*)(CFAllocatorRef))HSym("SecTaskCreateFromSelf");
    CFTypeRef (*copyEnt)(void *, CFStringRef, CFErrorRef *) =
        (CFTypeRef (*)(void *, CFStringRef, CFErrorRef *))HSym("SecTaskCopyValueForEntitlement");
    SBLog("HID sentask=%d copyent=%d", mkTask ? 1 : 0, copyEnt ? 1 : 0);
    if (!mkTask || !copyEnt) return;
    void *task = mkTask(NULL);
    if (!task) { SBLog("HID SecTask null"); return; }
    const char *keys[] = {
        "com.apple.private.hid.client.event-dispatch",
        "com.apple.backboard.hid.client.event-dispatch",
        "com.apple.private.hid.client.event-source",
        "com.apple.private.hid.client.admin",
        NULL
    };
    for (int i = 0; keys[i]; i++) {
        CFStringRef k = CFStringCreateWithCString(NULL, keys[i], kCFStringEncodingUTF8);
        CFTypeRef v = copyEnt(task, k, NULL);
        char desc[120] = {0};
        if (v) {
            if (CFGetTypeID(v) == CFBooleanGetTypeID()) {
                snprintf(desc, sizeof desc, "BOOL=%d", CFBooleanGetValue((CFBooleanRef)v));
            } else {
                snprintf(desc, sizeof desc, "type=%lu", (unsigned long)CFGetTypeID(v));
            }
            CFRelease(v);
        } else {
            snprintf(desc, sizeof desc, "null(no entitlement)");
        }
        SBLog("HID ent %s -> %s", keys[i], desc);
        CFRelease(k);
    }
    CFRelease((CFTypeRef)task);
}

static void *hidMakeEvent(double x, double y, int down) {
    // 1.6.49：父事件 + finger 子事件。裸 digitizer 事件系统不接受（rc=-210797）。
    void *(*mkDig)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t,
                   double, double, double, double, double, double, double, uint32_t, uint32_t) =
        (void *(*)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t,
                   double, double, double, double, double, double, double, uint32_t, uint32_t))
        HSym("IOHIDEventCreateDigitizerEvent");
    void *(*mkFinger)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
                      double, double, double, double, double, uint32_t, uint32_t, uint32_t) =
        (void *(*)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
                   double, double, double, double, double, uint32_t, uint32_t, uint32_t))
        HSym("IOHIDEventCreateDigitizerFingerEvent");
    void (*append)(void *, void *) = (void (*)(void *, void *))HSym("IOHIDEventAppendEvent");
    if (!mkDig) return NULL;
    uint32_t mask = down ? 0x3u : 0x1u;
    uint64_t ts = mach_absolute_time();
    // 1.6.52：options 必须带 kIOHIDEventOptionIsAbsolute(0x1)。
    // 传 0 时系统只把事件当成"用户活动"（会点亮屏幕），不会当成落在某个坐标的触摸。
    uint32_t opts = 0x1u;
    void *parent = mkDig(NULL, ts, 3u, 0u, 0u, mask, 0u,
                         x, y, 0.0, 0.0, 0.0, 0.0, 0.0, down ? 1u : 0u, opts);
    if (!parent) return NULL;
    if (mkFinger && append) {
        void *finger = mkFinger(NULL, ts, 0u, 2u, mask, x, y, 0.0, 0.0, 0.0,
                                down ? 1u : 0u, down ? 1u : 0u, opts);
        if (finger) {
            append(parent, finger);
            CFRelease((CFTypeRef)finger);
        }
    }
    return parent;
}

void SBHidFrontProbe(void) {
    Class ac = objc_getClass("SBApplicationController");
    Class ws = objc_getClass("SBWorkspace");
    SBLogSync("FP ac=%p ws=%p", ac, ws);
    if (ac) {
        unsigned n = 0;
        Method *m = class_copyMethodList(object_getClass((id)ac), &n);
        SBLogSync("FP ac +m n=%u", n);
        for (unsigned i = 0; i < n && i < 10; i++)
            SBLogSync("FP + %s", sel_getName(method_getName(m[i])));
        free(m);
        id inst = ((id (*)(id, SEL))objc_msgSend)((id)ac, @selector(sharedInstance));
        if (inst) {
            n = 0;
            m = class_copyMethodList(object_getClass(inst), &n);
            SBLogSync("FP ac -m n=%u", n);
            for (unsigned i = 0; i < n && i < 34; i++)
                SBLogSync("FP - %s", sel_getName(method_getName(m[i])));
            free(m);
        }
    }
    if (ws) {
        unsigned n = 0;
        Method *m = class_copyMethodList(object_getClass((id)ws), &n);
        SBLogSync("FP ws +m n=%u", n);
        for (unsigned i = 0; i < n && i < 8; i++)
            SBLogSync("FP + %s", sel_getName(method_getName(m[i])));
        free(m);
        id w = ((id (*)(id, SEL))objc_msgSend)((id)ws, @selector(mainWorkspace));
        if (w) {
            n = 0;
            m = class_copyMethodList(object_getClass(w), &n);
            SBLogSync("FP ws -m n=%u", n);
            for (unsigned i = 0; i < n && i < 26; i++)
                SBLogSync("FP - %s", sel_getName(method_getName(m[i])));
            free(m);
        }
    }
    SBLogSync("FP done");
}

const char *SBHidFront(void) {
    static char out[96];
    out[0] = 0;
    Class ac = objc_getClass("SBApplicationController");
    Class ws = objc_getClass("SBWorkspace");
    id inst = nil, app = nil;
    if (ac && class_respondsToSelector(object_getClass((id)ac), @selector(sharedInstance)))
        inst = ((id (*)(id, SEL))objc_msgSend)((id)ac, @selector(sharedInstance));
    if (inst && class_respondsToSelector(object_getClass(inst), @selector(frontmostApplication)))
        app = ((id (*)(id, SEL))objc_msgSend)(inst, @selector(frontmostApplication));
    if (!app && ws && class_respondsToSelector(object_getClass((id)ws), @selector(mainWorkspace))) {
        id w = ((id (*)(id, SEL))objc_msgSend)((id)ws, @selector(mainWorkspace));
        if (w && class_respondsToSelector(object_getClass(w), @selector(frontmostApplication)))
            app = ((id (*)(id, SEL))objc_msgSend)(w, @selector(frontmostApplication));
    }
    if (app) {
        id bid = nil;
        if (class_respondsToSelector(object_getClass(app), @selector(bundleIdentifier)))
            bid = ((id (*)(id, SEL))objc_msgSend)(app, @selector(bundleIdentifier));
        if (bid) [bid getCString:out maxLength:95 encoding:NSUTF8StringEncoding];
    }
    if (!out[0]) snprintf(out, sizeof out, "none(ac=%d inst=%d)", ac ? 1 : 0, inst ? 1 : 0);
    return out;
}

static int hidDispatchOne(void *client, double x, double y) {
    int (*dis)(void *, void *) = (int (*)(void *, void *))HSym("IOHIDEventSystemClientDispatchEvent");
    if (!client || !dis) return -100;
    void *evD = hidMakeEvent(x, y, 1);
    void *evU = hidMakeEvent(x, y, 0);
    int r1 = -1, r2 = -1;
    if (evD) r1 = dis(client, evD);
    if (evU) r2 = dis(client, evU);
    if (evD) CFRelease((CFTypeRef)evD);
    if (evU) CFRelease((CFTypeRef)evU);
    SBLog("HID dispatch down=%d up=%d", r1, r2);
    return r1;
}

// 一次完整点击：down + up，走已验证的 simple client 路径（不 schedule、不碰主线程）
static void *g_tapCli = NULL;

void SBHidTap(double x, double y) {
    void *(*simple)(void) = (void *(*)(void))HSym("IOHIDEventSystemClientCreateSimpleClient");
    void (*setQ)(void *, dispatch_queue_t) =
        (void (*)(void *, dispatch_queue_t))HSym("IOHIDEventSystemClientSetDispatchQueue");
    if (!g_tapCli) {
        if (!simple) { SBLogSync("TAPX no simple"); return; }
        g_tapCli = simple();
        if (!g_tapCli) { SBLogSync("TAPX no client"); return; }
        if (setQ) setQ(g_tapCli, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
        SBLogSync("TAPX client created %p", g_tapCli);
        // 1.6.57：1.6.54 在这里调 IOHIDEventSystemClientSetProperty 直接把 SB 打成 SIGSEGV
        // （崩溃栈顶 IOHIDEventSystemClientSetDispatchQueue，23:32 那份 ips），已彻底移除。
    }
    int rc = hidDispatchOne(g_tapCli, x, y);
    SBLogSync("TAPX rc=%d at %.0f,%.0f", rc, x, y);
    // 1.6.51：绝不 CFRelease 这个 simple client。1.6.50 里释放它直接 SIGSEGV。
    // 它由事件系统内部持有，进程生命周期内复用同一个。
}

// 1.6.57：BKS 合成派发最小实测。
// 目标不是马上点成，而是让服务端把"认不认"的回执吐出来；每步都夹日志，崩了也知道崩在哪步。
static id BKSCls(const char *n) { return (id)objc_getClass(n); }
static id BKSMsg0(id o, const char *s) {
    if (!o) return nil;
    SEL sel = sel_registerName(s);
    if (!class_respondsToSelector(object_getClass(o), sel)) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(o, sel);
}
static id BKSMsg1(id o, const char *s, id a) {
    if (!o) return nil;
    SEL sel = sel_registerName(s);
    if (!class_respondsToSelector(object_getClass(o), sel)) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(o, sel, a);
}
static void BKSMsgV1(id o, const char *s, id a) {
    if (!o) return;
    SEL sel = sel_registerName(s);
    if (!class_respondsToSelector(object_getClass(o), sel)) return;
    ((void (*)(id, SEL, id))objc_msgSend)(o, sel, a);
}

// 1.6.60：bkstap 全流程放到独立线程 + 独立日志 bks.log（每次 fopen 追加 + fflush，
// 规避 SBLogSync 缓冲在卡死/崩溃时丢行），派发那步再开一条线程 + 3 秒超时。
static void bksLog(const char *fmt, ...) {
    FILE *f = fopen(SB_HOME_DIR "/bks.log", "a");
    if (!f) return;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fputc('\n', f);
    fflush(f);
    fclose(f);
}

typedef struct { double x, y; } BksArg;
static volatile int g_bksDispDone = -1;
static id g_bksMgr = nil, g_bksReason = nil, g_bksArr = nil;

static void *bksDispatchThread(void *p) {
    (void)p;
    SEL sd = sel_registerName("dispatchDiscreteEventsForReason:withRules:");
    if (g_bksMgr && class_respondsToSelector(object_getClass(g_bksMgr), sd)) {
        bksLog("BKS dispatch enter");
        ((void (*)(id, SEL, id, id))objc_msgSend)(g_bksMgr, sd, g_bksReason, g_bksArr);
        bksLog("BKS dispatch returned");
    } else {
        bksLog("BKS dispatch sel missing");
    }
    g_bksDispDone = 1;
    return NULL;
}

static void *bksMainThread(void *p) {
    BksArg *a = (BksArg *)p;
    double x = a->x, y = a->y;
    free(a);
    bksLog("== run %.0f,%.0f", x, y);

    id cDesc = BKSCls("BKSHIDEventDescriptor");
    id cBa   = BKSCls("BKSHIDEventBaseAttributes");
    id cEnv  = BKSCls("BKSHIDEventDeferringEnvironment");
    id cDisp = BKSCls("BKSHIDEventDisplay");
    id cSnd  = BKSCls("BKSHIDEventSenderDescriptor");
    id cTgt  = BKSCls("BKSHIDEventDispatchingTarget");
    id cRule = BKSCls("BKSHIDEventDiscreteDispatchingRule");
    id cMgr  = BKSCls("BKSHIDEventDeliveryManager");
    id cPred2 = BKSCls("BKSHIDEventDiscreteDispatchingPredicate");
    bksLog("cls desc=%d ba=%d env=%d disp=%d snd=%d tgt=%d rule=%d mgr=%d pred=%d",
           cDesc?1:0, cBa?1:0, cEnv?1:0, cDisp?1:0, cSnd?1:0, cTgt?1:0, cRule?1:0, cMgr?1:0, cPred2?1:0);
    if (!cDesc || !cBa || !cMgr || !cRule) { bksLog("core class missing"); return NULL; }

    void *ev = hidMakeEvent(x, y, 1);
    bksLog("ev=%p", ev);
    if (!ev) return NULL;

    id d = BKSMsg1(cDesc, "descriptorForHIDEvent:", (id)ev);
    bksLog("desc=%p", d);
    if (!d) return NULL;

    id b0 = BKSMsg0(cBa, "alloc");
    id b = b0 ? BKSMsg0(b0, "init") : nil;
    bksLog("base=%p", b);
    if (!b) return NULL;

    id env = BKSMsg0(cEnv, "systemEnvironment");
    id dis = BKSMsg0(cDisp, "builtinDisplay");
    id snd = BKSMsg0(cSnd, "anyBuiltinTouchscreenDigitizer");
    bksLog("env=%p disp=%p sender=%p", env, dis, snd);
    if (env) BKSMsgV1(b, "setEnvironment:", env);
    if (dis) BKSMsgV1(b, "setDisplay:", dis);
    if (snd) BKSMsgV1(b, "setSource:", snd);
    bksLog("base filled");

    id pred = nil;
    if (cPred2 && env) {
        // 先把它的真实方法打出来（pred 为 0 说明我们猜的 init 不存在）
        unsigned n = 0;
        Method *m = class_copyMethodList(object_getClass(cPred2), &n);
        bksLog("DDP +%u", n);
        for (unsigned k = 0; k < n && k < 10; k++)
            bksLog("DDP + %s", sel_getName(method_getName(m[k])));
        free(m);
        n = 0;
        m = class_copyMethodList((Class)cPred2, &n);
        bksLog("DDP -%u", n);
        for (unsigned k = 0; k < n && k < 22; k++)
            bksLog("DDP - %s", sel_getName(method_getName(m[k])));
        free(m);

        const char *cands[] = {"_initWithSourceDescriptors:descriptors:", "_initWithEnvironment:display:token:", NULL};
        for (int ci = 0; cands[ci] && !pred; ci++) {
            id p0 = BKSMsg0(cPred2, "alloc");
            if (!p0) break;
            SEL si = sel_registerName(cands[ci]);
            if (!class_respondsToSelector(object_getClass(p0), si)) {
                bksLog("pred %s absent", cands[ci]);
                continue;
            }
            if (ci == 0)
                pred = ((id (*)(id, SEL, id, id))objc_msgSend)(p0, si, SBArr1(snd), SBArr1(d));
            else
                pred = ((id (*)(id, SEL, id, id, id))objc_msgSend)(p0, si, env, dis, nil);
            bksLog("pred via %s = %p", cands[ci], pred);
        }
        bksLog("pred=%p", pred);
    } else {
        bksLog("pred skip");
    }
    if (!pred) return NULL;

    id tgt = BKSMsg0(cTgt, "systemTarget");
    bksLog("target=%p", tgt);
    if (!tgt) return NULL;

    id rule = ((id (*)(id, SEL, id, id))objc_msgSend)(cRule,
               sel_registerName("ruleForDispatchingDiscreteEventsMatchingPredicate:toTarget:"),
               pred, tgt);
    bksLog("rule=%p", rule);
    if (!rule) return NULL;

    id mgr = BKSMsg0(cMgr, "sharedInstance");
    bksLog("mgr=%p", mgr);
    if (!mgr) return NULL;

    // authenticateMessage: 先试一次（这一步是同步的，但只传 descriptor，风险低）
    SEL sa = sel_registerName("authenticateMessage:");
    if (class_respondsToSelector(object_getClass(mgr), sa)) {
        id r = ((id (*)(id, SEL, id))objc_msgSend)(mgr, sa, d);
        bksLog("auth=%p", r);
    } else {
        bksLog("auth sel missing");
    }

    g_bksMgr = mgr;
    g_bksReason = SBStr("SiriBridgeTap");
    g_bksArr = SBArr1(rule);
    g_bksDispDone = 0;
    pthread_t th;
    if (pthread_create(&th, NULL, bksDispatchThread, NULL) == 0) {
        pthread_detach(th);
        for (int i = 0; i < 30 && g_bksDispDone != 1; i++) usleep(100000);
        bksLog("dispatch done=%d (1=returned, 0=timeout 3s)", g_bksDispDone);
    } else {
        bksLog("dispatch thread fail");
    }
    bksLog("== end");
    return NULL;
}

void SBHidBksTap(double x, double y) {
    BksArg *a = (BksArg *)malloc(sizeof(BksArg));
    if (!a) return;
    a->x = x;
    a->y = y;
    pthread_t th;
    if (pthread_create(&th, NULL, bksMainThread, a) == 0) pthread_detach(th);
    else free(a);
}

void SBHidProbe(void) {
    hidEntPrint();

    void *(*simple)(void) = (void *(*)(void))HSym("IOHIDEventSystemClientCreateSimpleClient");
    void (*setQ)(void *, dispatch_queue_t) =
        (void (*)(void *, dispatch_queue_t))HSym("IOHIDEventSystemClientSetDispatchQueue");
    int (*getType)(void *) = (int (*)(void *))HSym("IOHIDEventGetType");
    void *(*mkFinger)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
                      double, double, double, double, double, uint32_t, uint32_t, uint32_t) =
        (void *(*)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
                   double, double, double, double, double, uint32_t, uint32_t, uint32_t))
        HSym("IOHIDEventCreateDigitizerFingerEvent");
    void (*append)(void *, void *) = (void (*)(void *, void *))HSym("IOHIDEventAppendEvent");
    SBLogSync("HID2 simple=%d setQ=%d finger=%d append=%d getType=%d",
              simple ? 1 : 0, setQ ? 1 : 0, mkFinger ? 1 : 0, append ? 1 : 0, getType ? 1 : 0);

    if (!simple) { SBLogSync("HID2 no simple"); return; }
    void *c = simple();
    SBLogSync("HID2 client=%p", c);
    if (!c) return;
    if (setQ) {
        setQ(c, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
        SBLogSync("HID2 setQ done");
    }
    void *evD = hidMakeEvent(200.0, 400.0, 1);
    SBLogSync("HID2 evD=%p%s", evD, getType && evD ? "" : "");
    if (evD && getType) SBLogSync("HID2 evD type=%d", getType(evD));
    if (evD) {
        int rc = hidDispatchOne(c, 200.0, 400.0);
        SBLogSync("HID2 dispatch rc=%d", rc);
    }
    SBLogSync("HID2 done");
}
