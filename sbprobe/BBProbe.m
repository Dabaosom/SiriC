#include <stdio.h>
#include <stdarg.h>
#include <dlfcn.h>
#include <pthread.h>
#include <unistd.h>

// backboardd 探测件 v2（严格按上次 watchdog 的教训重做）：
//  1) 构造里只做一件事——起一条独立线程，立刻返回。绝不碰主线程、绝不 dispatch_sync。
//  2) client 的创建全部放在这条独立线程里，不挂主 runloop（本版干脆不挂任何 runloop）。
//  3) 一个事件都不发。本包只回答三个问题：dylib 有没有被注入、符号在不在、client 能不能建。
//
// 日志：上一次 bb.log 是空的，无法排除“注入没发生”和“写文件被拦”。这一版把同一行
// 同时写进多个候选路径，root 侧只要看哪个文件有内容，就能同时确定两件事。

static const char *kPaths[] = {
    "/var/mobile/Library/Caches/bbp.log",
    "/var/mobile/Library/SiriBridge/bbp.log",
    "/var/mobile/Documents/aiassist/bbp.log",
    "/private/var/tmp/bbp.log",
    "/var/root/bbp.log",
    NULL
};

static void bbW(const char *fmt, ...) {
    char line[320];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof line, fmt, ap);
    va_end(ap);
    for (int i = 0; kPaths[i]; i++) {
        FILE *f = fopen(kPaths[i], "a");
        if (!f) continue;
        fprintf(f, "%s\n", line);
        fclose(f);
    }
}

static void *bbMain(void *arg) {
    bbW("BBP thread start tid=%lu", (unsigned long)pthread_self());

    // 给 backboardd 一点时间把自己起完，避免在它初始化过程中去要 client
    usleep(500000);

    void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", 0x1);
    bbW("BBP iokit=%p", iokit);

    void *c1 = dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreate");
    void *c2 = dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreateSimpleClient");
    void *d1 = dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientDispatchEvent");
    void *s1 = dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientScheduleWithRunLoop");
    void *e1 = dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerEvent");
    void *e2 = dlsym(RTLD_DEFAULT, "IOHIDEventGetType");
    bbW("BBP sym create=%d simple=%d disp=%d sched=%d mk=%d gt=%d",
        c1 ? 1 : 0, c2 ? 1 : 0, d1 ? 1 : 0, s1 ? 1 : 0, e1 ? 1 : 0, e2 ? 1 : 0);

    if (c2) {
        void *cli = ((void *(*)(void *))c2)(NULL);
        bbW("BBP simple client=%p", cli);
    }
    if (c1) {
        void *cli = ((void *(*)(void *))c1)(NULL);
        bbW("BBP plain client=%p", cli);
    }

    bbW("BBP thread done");
    return NULL;
}

// 构造里只起线程，别的一概不做；pthread_create 不会阻塞调用者。
__attribute__((constructor)) static void BBPBoot(void) {
    bbW("BBP boot pid=%d", (int)getpid());
    pthread_t th;
    int rc = pthread_create(&th, NULL, bbMain, NULL);
    bbW("BBP thread spawn rc=%d", rc);
}
