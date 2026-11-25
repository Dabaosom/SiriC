#include <CoreFoundation/CoreFoundation.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <time.h>
#include <stdio.h>

#define PREFDOMAIN "com.doubao.siriaigh"

static void setv(const char *k, const char *v) {
    if (!v) v = "";
    CFStringRef key = CFStringCreateWithCString(0, k, kCFStringEncodingUTF8);
    CFStringRef val = CFStringCreateWithCString(0, v, kCFStringEncodingUTF8);
    CFStringRef dom = CFStringCreateWithCString(0, PREFDOMAIN, kCFStringEncodingUTF8);
    CFPreferencesSetAppValue(key, val, dom);
    CFPreferencesAppSynchronize(dom);
    CFRelease(key); CFRelease(val); CFRelease(dom);
}

static int has(const char *s, const char *sub) {
    if (!s || !sub) return 0;
    for (; *s; s++) {
        const char *p = s, *q = sub;
        while (*q && *p == *q) { p++; q++; }
        if (!*q) return 1;
    }
    return 0;
}

/* ===== S1：只触碰 NSURLSession 类与 sharedSession，不建 task、不联网 ===== */
static void s1_run(void) {
    setv("s1", "start");
    id cls = objc_getClass("NSURLSession");
    if (!cls) { setv("s1", "class-null"); return; }
    setv("s1", "class-ok");

    id shared = ((id(*)(id, SEL))objc_msgSend)(cls, sel_registerName("sharedSession"));
    if (!shared) { setv("s1", "shared-null"); return; }
    setv("s1", "shared-ok");

    id cfg = ((id(*)(id, SEL))objc_msgSend)(shared, sel_registerName("configuration"));
    if (!cfg) { setv("s1", "cfg-null"); return; }
    setv("s1", "cfg-ok");

    /* 只读取配置里的超时值，进一步确认对象可用 */
    double t = ((double(*)(id, SEL))objc_msgSend)(cfg, sel_registerName("timeoutIntervalForRequest"));
    char b[64];
    snprintf(b, sizeof b, "cfg-timeout-%.1f", t);
    setv("s1", b);
    setv("s1", "done");
}

static void *s1_thread(void *a) { (void)a; s1_run(); return 0; }

/* ===== 保持既有能力：只捕获识别文本（此前已验证稳定） ===== */
static IMP orig_speech = 0;
static long counter = 0;

static void my_speech(id self, SEL _cmd, id arg) {
    char text[2048];
    text[0] = 0;
    id best = ((id(*)(id, SEL))objc_msgSend)(arg, sel_registerName("af_bestTextInterpretation"));
    if (best) {
        const char *u = ((const char*(*)(id, SEL))objc_msgSend)(best, sel_registerName("UTF8String"));
        if (u) snprintf(text, sizeof text, "%s", u);
    }
    if (text[0]) {
        counter++;
        char nb[64];
        snprintf(nb, sizeof nb, "%ld-%ld", (long)time(0), counter);
        setv("text", text);
        setv("reqn", nb);
        if (has(text, "阶段一") || has(text, "阶段1")) {
            setv("s1", "triggered");
            pthread_t th;
            if (pthread_create(&th, 0, s1_thread, 0) == 0) pthread_detach(th);
        }
    } else {
        setv("text", "<nil>");
    }
    if (orig_speech) ((void(*)(id, SEL, id))orig_speech)(self, _cmd, arg);
}

static void *worker(void *a) {
    (void)a;
    sleep(3);
    id cls = objc_getClass("AFConnectionClientServiceDelegate");
    if (!cls) { setv("stage", "cls-null"); return 0; }
    Method m = class_getInstanceMethod(cls, sel_registerName("speechRecognized:"));
    if (!m) { setv("stage", "method-null"); return 0; }
    orig_speech = method_getImplementation(m);
    method_setImplementation(m, (IMP)my_speech);
    setv("stage", "hooked-s1");
    return 0;
}

__attribute__((constructor)) static void siri_init(void) {
    pthread_t th;
    if (pthread_create(&th, 0, worker, 0) == 0) pthread_detach(th);
}
