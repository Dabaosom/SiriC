// SBHid.m — 1.6.47
// SpringBoard 侧 HID 投递能力探测。
// 1.6.34 的结论是"默认 client dispatch rc=-210797"。这里补两件事：
//   1) 查自己到底有没有 hid event-dispatch entitlement（SecTask 自查询，不依赖外部工具）
//   2) 用 IOHIDEventSystemClientCreateWithType 的 Admin/Monitor 类型建 client 再投一次
// 全程不 ScheduleWithRunLoop、不 dispatch_sync 主线程（1.6.36 watchdog 的教训）。

#import "SiriBridge.h"
#import <dlfcn.h>

static void *HSym(const char *n) { return dlsym(RTLD_DEFAULT, n); }

static void hidEntPrint(void) {
    void *(*mkTask)(CFAllocatorRef) = (void *(*)(CFAllocatorRef))HSym("SecTaskCreateFromSelf");
    CFTypeRef (*copyEnt)(void *, CFStringRef, CFTypeRef *) =
        (CFTypeRef (*)(void *, CFStringRef, CFTypeRef *))HSym("SecTaskCopyValueForEntitlement");
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
        CFTypeRef v = NULL;
        int rc = copyEnt(task, k, &v);
        char desc[160] = {0};
        if (v) {
            if (CFGetTypeID(v) == CFBooleanGetTypeID()) {
                snprintf(desc, sizeof desc, "BOOL=%d", CFBooleanGetValue((CFBooleanRef)v));
            } else {
                snprintf(desc, sizeof desc, "type=%lu", (unsigned long)CFGetTypeID(v));
            }
            CFRelease(v);
        }
        SBLog("HID ent %s rc=%d %s", keys[i], rc, desc);
        CFRelease(k);
    }
    CFRelease((CFTypeRef)task);
}

static void *hidMakeEvent(double x, double y, int down) {
    void *(*mk)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t,
                double, double, double, double, double, double, double, uint32_t, uint32_t) =
        (void *(*)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t,
                   double, double, double, double, double, double, double, uint32_t, uint32_t))
        HSym("IOHIDEventCreateDigitizerEvent");
    if (!mk) return NULL;
    uint32_t mask = down ? 0x3u : 0x1u;
    return mk(NULL, mach_absolute_time(), 3u, 0u, 0u, mask, 0u,
              x, y, 0.0, 0.0, 0.0, 0.0, 0.0, down ? 1u : 0u, 0u);
}

static int hidDispatchOne(void *client, double x, double y) {
    void *(*dis)(void *, void *) = (int (*)(void *, void *))HSym("IOHIDEventSystemClientDispatchEvent");
    if (!client || !dis) return -100;
    void *ev = hidMakeEvent(x, y, 1);
    void *ev2 = hidMakeEvent(x, y, 0);
    int r1 = -1, r2 = -1;
    if (ev) r1 = dis(client, ev);
    if (ev2) r2 = dis(client, ev2);
    if (ev) CFRelease((CFTypeRef)ev);
    if (ev2) CFRelease((CFTypeRef)ev2);
    SBLog("HID dispatch down=%d up=%d", r1, r2);
    return r1;
}

void SBHidProbe(void) {
    hidEntPrint();

    void *(*withType)(CFAllocatorRef, int) = (void *(*)(CFAllocatorRef, int))HSym("IOHIDEventSystemClientCreateWithType");
    void *(*simple)(void) = (void *(*)(void))HSym("IOHIDEventSystemClientCreateSimpleClient");
    void *(*plain)(CFAllocatorRef) = (void *(*)(CFAllocatorRef))HSym("IOHIDEventSystemClientCreate");
    SBLog("HID sym withType=%d simple=%d plain=%d",
          withType ? 1 : 0, simple ? 1 : 0, plain ? 1 : 0);

    if (withType) {
        for (int t = 0; t <= 3; t++) {
            void *c = withType(NULL, t);
            SBLog("HID client type=%d ptr=%p", t, c);
            if (c) {
                int rc = hidDispatchOne(c, 200.0, 400.0);
                SBLog("HID type=%d firstrc=%d", t, rc);
                CFRelease((CFTypeRef)c);
            }
        }
    }
    if (simple) {
        void *c = simple();
        SBLog("HID simple ptr=%p", c);
        if (c) {
            int rc = hidDispatchOne(c, 200.0, 400.0);
            SBLog("HID simple firstrc=%d", rc);
            CFRelease((CFTypeRef)c);
        }
    }
    if (plain) {
        void *c = plain(NULL);
        SBLog("HID plain(no-schedule) ptr=%p", c);
        if (c) {
            int rc = hidDispatchOne(c, 200.0, 400.0);
            SBLog("HID plain firstrc=%d", rc);
            CFRelease((CFTypeRef)c);
        }
    }
    SBLog("HID probe done");
}
