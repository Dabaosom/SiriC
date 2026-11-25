#include <CoreFoundation/CoreFoundation.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <stdio.h>

/* 结果只经 notify 上报（不写偏好域，避免 cfprefsd 的 XPC guard 崩溃）。
   value = 阶段 * 10000 + 代码
   阶段 A..G = 1..7；0 = 语音捕获事件
   代码 100=start 200=ok1 300=ok2 400=ok3 500=done 900=fail 9xx=具体失败 */

#define URL_STR "https://apihub.agnes-ai.com/"
#define NOTIFY_NAME "com.doubao.stage"

static int (*p_register_check)(const char *, int *) = 0;
static int (*p_set_state)(int, unsigned long long) = 0;
static int (*p_post)(const char *) = 0;
static int g_tok = 0;
static int g_ready = 0;

static void ev_init(void) {
    if (g_ready) return;
    p_register_check = dlsym(RTLD_DEFAULT, "notify_register_check");
    p_set_state = dlsym(RTLD_DEFAULT, "notify_set_state");
    p_post = dlsym(RTLD_DEFAULT, "notify_post");
    if (p_register_check && p_set_state && p_post && p_register_check(NOTIFY_NAME, &g_tok) == 0) {
        g_ready = 1;
    }
}

static void ev(int stage, int code) {
    ev_init();
    if (!g_ready) return;
    unsigned long long v = (unsigned long long)(stage * 10000 + code);
    p_set_state(g_tok, v);
    p_post(NOTIFY_NAME);
}

static id CL(const char *n) { return (id)objc_getClass(n); }

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
    ev(1, 100);
    id s = ((id(*)(id, SEL, const char *))objc_msgSend)(CL("NSString"),
            sel_registerName("stringWithUTF8String:"), "foundation-probe");
    if (!s) { ev(1, 901); return; }
    ev(1, 200);
    unsigned long len = ((unsigned long(*)(id, SEL))objc_msgSend)(s, sel_registerName("length"));
    if (len == 16) ev(1, 300); else ev(1, 902);
    ev(1, 500);
}

/* ---------- B: NSURL ---------- */
static void stageB(void) {
    ev(2, 100);
    id s = ((id(*)(id, SEL, const char *))objc_msgSend)(CL("NSString"),
            sel_registerName("stringWithUTF8String:"), URL_STR);
    if (!s) { ev(2, 901); return; }
    ev(2, 200);
    id url = ((id(*)(id, SEL, id))objc_msgSend)(CL("NSURL"),
             sel_registerName("URLWithString:"), s);
    if (!url) { ev(2, 902); return; }
    ev(2, 300);
    id abs = ((id(*)(id, SEL))objc_msgSend)(url, sel_registerName("absoluteString"));
    if (abs) ev(2, 400); else ev(2, 903);
    ev(2, 500);
}

/* ---------- C: CFNetwork 加载 ---------- */
static void stageC(void) {
    ev(3, 100);
    void *h = dlopen("/System/Library/Frameworks/CFNetwork.framework/CFNetwork", RTLD_LAZY | RTLD_GLOBAL);
    if (!h) { ev(3, 901); return; }
    ev(3, 200);
    void *sym = dlsym(RTLD_DEFAULT, "CFHTTPMessageCreateEmpty");
    if (sym) ev(3, 300); else ev(3, 902);
    ev(3, 500);
}

/* ---------- D: NSURLSessionConfiguration ---------- */
static void stageD(void) {
    ev(4, 100);
    id cfg = ((id(*)(id, SEL))objc_msgSend)(CL("NSURLSessionConfiguration"),
             sel_registerName("defaultSessionConfiguration"));
    if (!cfg) { ev(4, 901); return; }
    ev(4, 200);
    double t = ((double(*)(id, SEL))objc_msgSend)(cfg, sel_registerName("timeoutIntervalForRequest"));
    if (t > 0) ev(4, 300); else ev(4, 902);
    ev(4, 500);
}

/* ---------- E: NSURLSession 初始化 ---------- */
static void stageE(void) {
    ev(5, 100);
    id ses = ((id(*)(id, SEL))objc_msgSend)(CL("NSURLSession"), sel_registerName("sharedSession"));
    if (!ses) { ev(5, 901); return; }
    ev(5, 200);
    id cfg = ((id(*)(id, SEL))objc_msgSend)(ses, sel_registerName("configuration"));
    if (cfg) ev(5, 300); else ev(5, 902);
    ev(5, 500);
}

/* ---------- F/G: HTTPS ---------- */
static void stageFG(int stage, int wantData) {
    ev(stage, 100);
    id s = ((id(*)(id, SEL, const char *))objc_msgSend)(CL("NSString"),
            sel_registerName("stringWithUTF8String:"), URL_STR);
    if (!s) { ev(stage, 901); return; }
    id url = ((id(*)(id, SEL, id))objc_msgSend)(CL("NSURL"),
             sel_registerName("URLWithString:"), s);
    if (!url) { ev(stage, 902); return; }
    ev(stage, 200);
    id req = ((id(*)(id, SEL, id))objc_msgSend)(CL("NSMutableURLRequest"),
            sel_registerName("requestWithURL:"), url);
    if (!req) { ev(stage, 902); return; }
    ev(stage, 300);
    id ses = ((id(*)(id, SEL))objc_msgSend)(CL("NSURLSession"), sel_registerName("sharedSession"));
    if (!ses) { ev(stage, 903); return; }
    ev(stage, 400);

    void (^handler)(id, id, id) = ^(id data, id resp, id err) {
        if (err) {
            long c = ((long(*)(id, SEL))objc_msgSend)(err, sel_registerName("code"));
            ev(stage, 910 + (int)(c % 80));
            return;
        }
        ev(stage, 600);
        if (wantData && data) {
            unsigned long len = ((unsigned long(*)(id, SEL))objc_msgSend)(data, sel_registerName("length"));
            ev(stage, 700 + (int)(len > 70 ? 70 : len));
        }
        ev(stage, 500);
    };

    id task = ((id(*)(id, SEL, id, id))objc_msgSend)(ses,
            sel_registerName("dataTaskWithRequest:completionHandler:"), req, (id)handler);
    if (!task) { ev(stage, 904); return; }
    ev(stage, 450);
    ((void(*)(id, SEL))objc_msgSend)(task, sel_registerName("resume"));
    ev(stage, 460);
}

static void *runner(void *arg) {
    int which = (int)(long)arg;
    switch (which) {
        case 0: stageA(); break;
        case 1: stageB(); break;
        case 2: stageC(); break;
        case 3: stageD(); break;
        case 4: stageE(); break;
        case 5: stageFG(6, 0); break;
        case 6: stageFG(7, 1); break;
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
        ev(0, 100 + (int)(counter > 90 ? 90 : counter));

        int which = -1;
        if (has_nospace(text, "阶段A") || has_nospace(text, "阶段a")) which = 0;
        else if (has_nospace(text, "阶段B") || has_nospace(text, "阶段b")) which = 1;
        else if (has_nospace(text, "阶段C") || has_nospace(text, "阶段c")) which = 2;
        else if (has_nospace(text, "阶段D") || has_nospace(text, "阶段d")) which = 3;
        else if (has_nospace(text, "阶段E") || has_nospace(text, "阶段e")
              || has_nospace(text, "阶段一") || has_nospace(text, "阶段1")
              || has_nospace(text, "阶段伊")) which = 4;
        else if (has_nospace(text, "阶段F") || has_nospace(text, "阶段f")) which = 5;
        else if (has_nospace(text, "阶段G") || has_nospace(text, "阶段g")) which = 6;

        if (which < 0) {
            int n = 0;
            const char *p = text;
            while (*p && n < 6) { if (*p != ' ') n++; p++; }
            ev(9, 100 + n);
        }

        if (which >= 0) {
            pthread_t th;
            if (pthread_create(&th, 0, runner, (void *)(long)which) == 0) pthread_detach(th);
        }
    }
    if (orig_speech) ((void(*)(id, SEL, id))orig_speech)(self, _cmd, arg);
}

static void *worker(void *a) {
    (void)a;
    sleep(3);
    Class cls = objc_getClass("AFConnectionClientServiceDelegate");
    if (!cls) { ev(8, 901); return 0; }
    Method m = class_getInstanceMethod(cls, sel_registerName("speechRecognized:"));
    if (!m) { ev(8, 902); return 0; }
    orig_speech = method_getImplementation(m);
    method_setImplementation(m, (IMP)my_speech);
    ev(8, 500);
    return 0;
}

__attribute__((constructor)) static void siri_init(void) {
    pthread_t th;
    if (pthread_create(&th, 0, worker, 0) == 0) pthread_detach(th);
}
