#include <CoreFoundation/CoreFoundation.h>
#include <CoreFoundation/CFBundle.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <time.h>
#include <stdio.h>

/* 分阶段探针：A..G 每个阶段只在被触发时执行，互不打包。
   触发词：说 “阶段A” ... “阶段G”（自动去除空格后匹配）。
   结果分别写 sA..sG，不覆盖其它阶段。 */

#define PREFDOMAIN "com.doubao.siriaigh"
#define URL_STR    "https://apihub.agnes-ai.com/"

static void setv(const char *k, const char *v) {
    if (!v) v = "";
    CFStringRef key = CFStringCreateWithCString(0, k, kCFStringEncodingUTF8);
    CFStringRef val = CFStringCreateWithCString(0, v, kCFStringEncodingUTF8);
    CFStringRef dom = CFStringCreateWithCString(0, PREFDOMAIN, kCFStringEncodingUTF8);
    CFPreferencesSetAppValue(key, val, dom);
    CFPreferencesAppSynchronize(dom);
    CFRelease(key); CFRelease(val); CFRelease(dom);
}

/* 去掉空白后判断子串 */
static int has_nospace(const char *s, const char *sub) {
    if (!s || !sub) return 0;
    char a[2200]; int n = 0;
    for (const char *p = s; *p && n < 2100; p++) {
        if (*p == ' ' || *p == '\t') continue;
        a[n++] = *p;
    }
    a[n] = 0;
    for (const char *p = a; *p; p++) {
        const char *q = sub, *r = p;
        while (*q && *r == *q) { r++; q++; }
        if (!*q) return 1;
    }
    return 0;
}

/* ---------- A: Foundation ---------- */
static void stageA(void) {
    setv("sA", "start");
    id s = ((id(*)(id, SEL, const char *))objc_msgSend)(objc_getClass("NSString"),
            sel_registerName("stringWithUTF8String:"), "foundation-probe");
    if (!s) { setv("sA", "str-null"); return; }
    setv("sA", "str-ok");
    unsigned long len = ((unsigned long(*)(id, SEL))objc_msgSend)(s, sel_registerName("length"));
    char b[64];
    snprintf(b, sizeof b, "len=%lu", len);
    setv("sA", b);
    setv("sA", "done");
}

/* ---------- B: NSURL（运行期字符串，不用字面量） ---------- */
static void stageB(void) {
    setv("sB", "start");
    id url = ((id(*)(id, SEL, const char *))objc_msgSend)(objc_getClass("NSURL"),
             sel_registerName("URLWithString:"), URL_STR);
    if (!url) { setv("sB", "url-null"); return; }
    setv("sB", "url-ok");
    id abs = ((id(*)(id, SEL))objc_msgSend)(url, sel_registerName("absoluteString"));
    if (abs) {
        const char *u = ((const char*(*)(id, SEL))objc_msgSend)(abs, sel_registerName("UTF8String"));
        if (u) setv("sB", u);
    }
    setv("sB", "done");
}

/* ---------- C: CFNetwork 加载 ---------- */
static void stageC(void) {
    setv("sC", "start");
    void *h = dlopen("/System/Library/Frameworks/CFNetwork.framework/CFNetwork", RTLD_LAZY | RTLD_GLOBAL);
    char b[160];
    if (!h) {
        snprintf(b, sizeof b, "dlopen-fail %s", dlerror() ? dlerror() : "no-err");
        setv("sC", b);
        return;
    }
    snprintf(b, sizeof b, "dlopen-ok %p", h);
    setv("sC", b);
    void *sym = dlsym(RTLD_DEFAULT, "CFHTTPMessageCreateEmpty");
    snprintf(b, sizeof b, "sym %s", sym ? "found" : "missing");
    setv("sC", b);
    setv("sC", "done");
}

/* ---------- D: NSURLSessionConfiguration ---------- */
static void stageD(void) {
    setv("sD", "start");
    id cfg = ((id(*)(id, SEL))objc_msgSend)(objc_getClass("NSURLSessionConfiguration"),
             sel_registerName("defaultSessionConfiguration"));
    if (!cfg) { setv("sD", "cfg-null"); return; }
    setv("sD", "cfg-ok");
    double t = ((double(*)(id, SEL))objc_msgSend)(cfg, sel_registerName("timeoutIntervalForRequest"));
    char b[64];
    snprintf(b, sizeof b, "timeout=%.1f", t);
    setv("sD", b);
    setv("sD", "done");
}

/* ---------- E: NSURLSession 初始化（sharedSession，不带 config） ---------- */
static void stageE(void) {
    setv("sE", "start");
    id ses = ((id(*)(id, SEL))objc_msgSend)(objc_getClass("NSURLSession"),
            sel_registerName("sharedSession"));
    if (!ses) { setv("sE", "session-null"); return; }
    setv("sE", "session-ok");
    id cfg = ((id(*)(id, SEL))objc_msgSend)(ses, sel_registerName("configuration"));
    setv("sE", cfg ? "cfg-ok" : "cfg-null");
    setv("sE", "done");
}

/* ---------- F/G: HTTPS 发起与返回（共用一套最小请求） ---------- */
static void stageFG(const char *key, int wantData) {
    setv(key, "start");
    id url = ((id(*)(id, SEL, const char *))objc_msgSend)(objc_getClass("NSURL"),
             sel_registerName("URLWithString:"), URL_STR);
    if (!url) { setv(key, "url-null"); return; }
    setv(key, "url-ok");

    id req = ((id(*)(id, SEL, id))objc_msgSend)(objc_getClass("NSMutableURLRequest"),
            sel_registerName("requestWithURL:"), url);
    if (!req) { setv(key, "req-null"); return; }
    setv(key, "req-ok");

    id ses = ((id(*)(id, SEL))objc_msgSend)(objc_getClass("NSURLSession"), sel_registerName("sharedSession"));
    if (!ses) { setv(key, "session-null"); return; }
    setv(key, "session-ok");

    void (^handler)(id, id, id) = ^(id data, id resp, id err) {
        if (err) {
            long c = ((long(*)(id, SEL))objc_msgSend)(err, sel_registerName("code"));
            char b[64];
            snprintf(b, sizeof b, "callback-err %ld", c);
            setv(key, b);
            setv(key, "done");
            return;
        }
        setv(key, "callback-ok");
        if (wantData) {
            unsigned long len = data ? ((unsigned long(*)(id, SEL))objc_msgSend)(data, sel_registerName("length")) : 0;
            char b[64];
            snprintf(b, sizeof b, "data-len=%lu", len);
            setv(key, b);
        }
        setv(key, "done");
    };

    id task = ((id(*)(id, SEL, id, id))objc_msgSend)(ses,
            sel_registerName("dataTaskWithRequest:completionHandler:"), req, handler);
    if (!task) { setv(key, "task-null"); return; }
    setv(key, "task-ok");
    ((void(*)(id, SEL))objc_msgSend)(task, sel_registerName("resume"));
    setv(key, "resumed");
}

static void *runner(void *arg) {
    int which = (int)(long)arg;
    switch (which) {
        case 0: stageA(); break;
        case 1: stageB(); break;
        case 2: stageC(); break;
        case 3: stageD(); break;
        case 4: stageE(); break;
        case 5: stageFG("sF", 0); break;
        case 6: stageFG("sG", 1); break;
    }
    return 0;
}

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

        int which = -1;
        if (has_nospace(text, "阶段A") || has_nospace(text, "阶段a")) which = 0;
        else if (has_nospace(text, "阶段B") || has_nospace(text, "阶段b")) which = 1;
        else if (has_nospace(text, "阶段C") || has_nospace(text, "阶段c")) which = 2;
        else if (has_nospace(text, "阶段D") || has_nospace(text, "阶段d")) which = 3;
        else if (has_nospace(text, "阶段E") || has_nospace(text, "阶段e")) which = 4;
        else if (has_nospace(text, "阶段F") || has_nospace(text, "阶段f")) which = 5;
        else if (has_nospace(text, "阶段G") || has_nospace(text, "阶段g")) which = 6;

        if (which >= 0) {
            pthread_t th;
            if (pthread_create(&th, 0, runner, (void *)(long)which) == 0) pthread_detach(th);
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
    setv("stage", "hooked-stages");
    return 0;
}

__attribute__((constructor)) static void siri_init(void) {
    pthread_t th;
    if (pthread_create(&th, 0, worker, 0) == 0) pthread_detach(th);
}
