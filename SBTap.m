#import "SiriBridge.h"
#include <dlfcn.h>
#include <mach/mach_time.h>

// 1.6.32：点击（B 方案）第一步只做弹药检查，绝不真发事件。
void SBTapProbe(void) {
    void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    SBLogSync("TAP iokit=%p", iokit);

    void *sysCreate = dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreate");
    void *sysDispatch = dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientDispatchEvent");
    void *sysSetQueue = dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientSetDispatchQueue");
    void *evFinger = dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerFingerEvent");
    void *evDigitizer = dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerEvent");
    void *evSetInt = dlsym(RTLD_DEFAULT, "IOHIDEventSetIntegerValue");
    void *evSetFloat = dlsym(RTLD_DEFAULT, "IOHIDEventSetFloatValue");
    void *gsSend = dlsym(RTLD_DEFAULT, "GSSendEvent");

    SBLogSync("TAP sym clientCreate=%d dispatch=%d setQueue=%d",
              sysCreate ? 1 : 0, sysDispatch ? 1 : 0, sysSetQueue ? 1 : 0);
    SBLogSync("TAP sym finger=%d digitizer=%d setInt=%d setFloat=%d gs=%d",
              evFinger ? 1 : 0, evDigitizer ? 1 : 0, evSetInt ? 1 : 0,
              evSetFloat ? 1 : 0, gsSend ? 1 : 0);
}

// ============ 1.6.34：SpringBoard 侧真发一次触摸 ============
// CreateSimpleClient 免队列可 dispatch（1.6.32 已验证存在且能创建）。
// 事件用 IOHIDEventCreateDigitizerEvent 的 16 参形态（私有头里的标准声明）。
// 这一步有栈风险：参数个数/类型对不上会直接崩 SpringBoard。因此只在明确触发时发一次。
static void *g_hid = NULL;
static int g_tapArmed = 0;
static void *g_mk = NULL;
static void *g_dis = NULL;
static void *g_gt = NULL;

static void *SBTapClient(void) {
    if (g_hid) return g_hid;
    void *p = dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreateSimpleClient");
    if (!p) { SBLogSync("TAP no simpleClient"); return NULL; }
    typedef void *(*F)(CFAllocatorRef);
    g_hid = ((F)p)(NULL);
    SBLogSync("TAP client(simple)=%p", g_hid);
    return g_hid;
}

static int SBTapSend(double x, double y, int down) {
    if (!g_mk) g_mk = dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerEvent");
    if (!g_dis) g_dis = dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientDispatchEvent");
    if (!g_gt) g_gt = dlsym(RTLD_DEFAULT, "IOHIDEventGetType");
    if (!g_mk || !g_dis) { SBLogSync("TAP no symbols mk=%d dis=%d", g_mk ? 1 : 0, g_dis ? 1 : 0); return -1; }

    typedef void *(*MkFn)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
                          uint32_t, uint32_t, double, double, double,
                          double, double, double, double, uint32_t, uint32_t);
    uint32_t mask = down ? 0x3u : 0x1u;   // Range|Touch / Range
    void *ev = ((MkFn)g_mk)(NULL, mach_absolute_time(), 3u /*Hand*/, 0u, 0u, mask, 0u,
                            x, y, 0.0, 0.0, 0.0, 0.0, 0.0, down ? 1u : 0u, 0u);
    if (!ev) { SBLogSync("TAP ev null down=%d", down); return -2; }
    if (g_gt) {
        typedef int (*GTFn)(void *);
        SBLogSync("TAP evtype=%d down=%d", ((GTFn)g_gt)(ev), down);
    }
    void *cli = SBTapClient();
    if (!cli) { CFRelease((CFTypeRef)ev); return -3; }
    typedef int (*DisFn)(void *, void *);
    int rc = ((DisFn)g_dis)(cli, ev);
    CFRelease((CFTypeRef)ev);
    SBLogSync("TAP dispatch rc=%d down=%d", rc, down);
    return rc;
}

// 一次完整点击：按下 → 停 60ms → 抬起
int SBTapAt(double x, double y) {
    SBLogSync("TAP at %.0f,%.0f", x, y);
    int a = SBTapSend(x, y, 1);
    usleep(60000);
    int b = SBTapSend(x, y, 0);
    SBLogSync("TAP done down=%d up=%d", a, b);
    return 0;
}

// 只发一次，避免反复点
void SBTapOnce(double x, double y) {
    if (g_tapArmed) return;
    g_tapArmed = 1;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        SBTapAt(x, y);
    });
}
