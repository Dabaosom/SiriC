#import "SiriBridge.h"
#include <dlfcn.h>

// 1.6.32：点击（B 方案）的第一步只做弹药检查，绝不真发事件。
// 上一轮已经因为常量对象黑屏一次，这次先把私有符号是否存在、客户端能不能创建
// 用日志确认清楚，再决定下一步怎么发触摸。
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

    if (sysCreate) {
        typedef void *(*CreateFn)(CFAllocatorRef);
        void *client = ((CreateFn)sysCreate)(NULL);
        SBLogSync("TAP client=%p", client);
        if (client && sysDispatch) {
            typedef int (*SetQFn)(void *, void *);
            if (sysSetQueue) {
                int rc = ((SetQFn)sysSetQueue)(client, NULL);
                SBLogSync("TAP setqueue rc=%d", rc);
            }
            // 只查能不能拿到 client，不 dispatch 任何事件
            SBLogSync("TAP client ok (no event sent)");
        }
    }

    // 1.6.32 补：SetDispatchQueue 需要真的 dispatch queue，传 NULL 必然失败（上面 rc 是负值）。
    // CreateSimpleClient 才是“免队列、直接 dispatch”的入口，先确认它在不在。
    void *simple = dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreateSimpleClient");
    SBLogSync("TAP simple=%d", simple ? 1 : 0);
    if (simple) {
        typedef void *(*SimpleFn)(CFAllocatorRef);
        void *c2 = ((SimpleFn)simple)(NULL);
        SBLogSync("TAP simple client=%p", c2);
    }
}
