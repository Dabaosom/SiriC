#include <stdio.h>
#include <dlfcn.h>
#include <stdint.h>
#include <string.h>

// 极简 backboardd 探测件：只确认“我进来了”“符号在不在”“client 能不能建”。
// 一个事件都不发，不 hook 任何系统方法，所以崩面只剩这几十行。
// 刻意不静态链接 libnotify —— backboardd 早期启动时任何链接失败都会让它起不来，
// 所以 notify 也全部走 dlopen/dlsym，拿不到就静默跳过。

static const char *kPaths[] = {
    "/var/mobile/Documents/aiassist/bb.log",
    "/tmp/bb.log",
    "/var/mobile/bb.log",
    NULL
};

static char g_bestPath[128] = {0};

static void bbLog(const char *line) {
    if (g_bestPath[0]) {
        FILE *f = fopen(g_bestPath, "a");
        if (f) { fprintf(f, "%s\n", line); fclose(f); return; }
        g_bestPath[0] = 0;
    }
    for (int i = 0; kPaths[i]; i++) {
        FILE *f = fopen(kPaths[i], "a");
        if (f) {
            fprintf(f, "%s\n", line);
            fclose(f);
            strncpy(g_bestPath, kPaths[i], sizeof g_bestPath - 1);
            return;
        }
    }
}

static void bbSay(uint32_t code, uint32_t val) {
    static int (*pCheck)(const char *, int *) = NULL;
    static int (*pSetState)(int, uint64_t) = NULL;
    static int (*pPost)(const char *) = NULL;
    static int tried = 0;
    if (!tried) {
        tried = 1;
        void *h = dlopen("/usr/lib/libnotify.dylib", 0x1);
        if (h) {
            pCheck = dlsym(h, "notify_register_check");
            pSetState = dlsym(h, "notify_set_state");
            pPost = dlsym(h, "notify_post");
        }
    }
    if (!pCheck || !pSetState || !pPost) return;
    int tok = 0;
    if (pCheck("com.doubao.bbsay", &tok) != 0) return;
    pSetState(tok, ((uint64_t)(code & 0xFF) << 32) | (uint64_t)(val & 0xFFFFFFFF));
    pPost("com.doubao.bbsay");
}

__attribute__((constructor)) static void BBTapBoot(void) {
    bbLog("BB boot");
    bbSay(1, 1);

    void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", 0x1);
    bbLog(iokit ? "BB iokit ok" : "BB iokit null");

    void *c1 = dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreate");
    void *c2 = dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreateSimpleClient");
    void *d1 = dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientDispatchEvent");
    void *d2 = dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientScheduleWithRunLoop");
    void *e1 = dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerEvent");
    void *e2 = dlsym(RTLD_DEFAULT, "IOHIDEventGetType");
    uint32_t bits = (c1 ? 1u : 0u) | (c2 ? 2u : 0u) | (d1 ? 4u : 0u) |
                    (d2 ? 8u : 0u) | (e1 ? 16u : 0u) | (e2 ? 32u : 0u);
    char buf[128];
    snprintf(buf, sizeof buf, "BB sym bits=%u create=%d simple=%d disp=%d sched=%d mk=%d gt=%d",
             bits, c1 ? 1 : 0, c2 ? 1 : 0, d1 ? 1 : 0, d2 ? 1 : 0, e1 ? 1 : 0, e2 ? 1 : 0);
    bbLog(buf);
    bbSay(2, bits);

    // 只创建 client，不投递任何事件
    if (c1) {
        void *cl = ((void *(*)(void *))c1)(NULL);
        bbLog(cl ? "BB client ok" : "BB client null");
        bbSay(3, cl ? 1 : 0);
    }
    if (c2) {
        void *cl = ((void *(*)(void *))c2)(NULL);
        bbLog(cl ? "BB simple ok" : "BB simple null");
        bbSay(4, cl ? 1 : 0);
    }

    bbLog("BB done");
    bbSay(5, 1);
}
