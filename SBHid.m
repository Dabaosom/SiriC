// SBHid.m — 1.6.47
// SpringBoard 侧 HID 投递能力探测。
// 1) 查自己有没有 hid event-dispatch entitlement（SecTask 自查询）
// 2) 用 IOHIDEventSystemClientCreateWithType 的 Admin/Monitor 类型建 client 再投一次
// 全程不 ScheduleWithRunLoop、不 dispatch_sync 主线程（1.6.36 watchdog 的教训）。

#import "SiriBridge.h"
#import <dlfcn.h>
#import <mach/mach_time.h>

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
    void *parent = mkDig(NULL, ts, 3u, 0u, 0u, mask, 0u,
                         x, y, 0.0, 0.0, 0.0, 0.0, 0.0, down ? 1u : 0u, 0u);
    if (!parent) return NULL;
    if (mkFinger && append) {
        void *finger = mkFinger(NULL, ts, 0u, 2u, mask, x, y, 0.0, 0.0, 0.0,
                                down ? 1u : 0u, down ? 1u : 0u, 0u);
        if (finger) {
            append(parent, finger);
            CFRelease((CFTypeRef)finger);
        }
    }
    return parent;
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
