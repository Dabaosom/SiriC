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

/* 诊断用：把识别文本逐字符吐出。value = 10000000 + idx * 65536 + codepoint */
static void dump_text(const char *text) {
    ev_init();
    if (!g_ready) return;
    const unsigned char *p = (const unsigned char *)text;
    int idx = 0;
    while (*p && idx < 10) {
        unsigned int cp = 0;
        if (p[0] >= 0xF0) { cp = 0; p += 4; }
        else if (p[0] >= 0xE0) { cp = ((p[0] & 0x0F) << 12) | ((p[1] & 0x3F) << 6) | (p[2] & 0x3F); p += 3; }
        else if (p[0] >= 0xC0) { cp = ((p[0] & 0x1F) << 6) | (p[1] & 0x3F); p += 2; }
        else { cp = p[0]; p += 1; }
        if (cp == ' ') { continue; }
        unsigned long long v = 10000000ULL + (unsigned long long)idx * 65536ULL + cp;
        p_set_state(g_tok, v);
        p_post(NOTIFY_NAME);
        usleep(250000);
        idx++;
    }
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
static volatile long g_stage = 0;
static volatile unsigned long g_bytes = 0;
static id g_ses = 0;
static id g_dg = 0;

static void dl_recv(id self, SEL _cmd, id ses, id task, id data) {
    (void)self; (void)_cmd; (void)ses; (void)task;
    if (data) {
        unsigned long n = ((unsigned long(*)(id, SEL))objc_msgSend)(data, sel_registerName("length"));
        g_bytes += n;
    }
}

static void dl_done(id self, SEL _cmd, id ses, id task, id err) {
    (void)self; (void)_cmd; (void)ses; (void)task;
    long st = g_stage;
    if (err) {
        long c = ((long(*)(id, SEL))objc_msgSend)(err, sel_registerName("code"));
        ev(st, 910 + (int)(c % 80));
        return;
    }
    ev(st, 600);
    usleep(300000);
    unsigned long len = g_bytes;
    ev(st, 700 + (int)(len > 70 ? 70 : (long)len));
    usleep(300000);
    ev(st, 500);
}

static id make_delegate(void) {
    Class dc = objc_getClass("SiriNetDelegate");
    if (!dc) {
        dc = objc_allocateClassPair(objc_getClass("NSObject"), "SiriNetDelegate", 0);
        if (!dc) return 0;
        class_addMethod(dc, sel_registerName("URLSession:dataTask:didReceiveData:"), (IMP)dl_recv, "v@:@@@");
        class_addMethod(dc, sel_registerName("URLSession:task:didCompleteWithError:"), (IMP)dl_done, "v@:@@@");
        objc_registerClassPair(dc);
    }
    return ((id(*)(id, SEL))objc_msgSend)((id)dc, sel_registerName("new"));
}

static void stageFG(int stage, int wantData) {
    ev(stage, 100);
    g_stage = stage;
    g_bytes = 0;
    void *cfh = dlopen("/System/Library/Frameworks/CFNetwork.framework/CFNetwork",
                       RTLD_NOW | RTLD_GLOBAL);
    if (!cfh) { ev(stage, 905); return; }
    ev(stage, 110);
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

    id dg = make_delegate();
    if (!dg) { ev(stage, 907); return; }
    id cfg = ((id(*)(id, SEL))objc_msgSend)(CL("NSURLSessionConfiguration"),
             sel_registerName("defaultSessionConfiguration"));
    if (!cfg) { ev(stage, 908); return; }
    id ses = ((id(*)(id, SEL, id, id, id))objc_msgSend)(CL("NSURLSession"),
            sel_registerName("sessionWithConfiguration:delegate:delegateQueue:"),
            cfg, dg, (id)0);
    if (!ses) { ev(stage, 903); return; }
    g_ses = ses;
    g_dg = dg;
    ev(stage, 400);
    (void)wantData;

    id task = ((id(*)(id, SEL, id))objc_msgSend)(ses,
            sel_registerName("dataTaskWithRequest:"), req);
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

static void fg_go5(id self, SEL _cmd) { (void)self; (void)_cmd; sleep(1); stageFG(6, 0); }
static void fg_go6(id self, SEL _cmd) { (void)self; (void)_cmd; sleep(1); stageFG(7, 1); }

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
        if (has_nospace(text, "阶段A") || has_nospace(text, "阶段a")
         || has_nospace(text, "阶段诶") || has_nospace(text, "阶段欸")
         || has_nospace(text, "阶段哎") || has_nospace(text, "阶段壹")
         || has_nospace(text, "阶段甲")) which = 0;
        else if (has_nospace(text, "阶段B") || has_nospace(text, "阶段b")
              || has_nospace(text, "阶段比") || has_nospace(text, "阶段逼")
              || has_nospace(text, "阶段二") || has_nospace(text, "阶段2")) which = 1;
        else if (has_nospace(text, "阶段C") || has_nospace(text, "阶段c")
              || has_nospace(text, "阶段西") || has_nospace(text, "阶段希")
              || has_nospace(text, "阶段三") || has_nospace(text, "阶段3")) which = 2;
        else if (has_nospace(text, "阶段D") || has_nospace(text, "阶段d")
              || has_nospace(text, "阶段迪") || has_nospace(text, "阶段弟")
              || has_nospace(text, "阶段四") || has_nospace(text, "阶段4")) which = 3;
        else if (has_nospace(text, "阶段E") || has_nospace(text, "阶段e")
              || has_nospace(text, "阶段一") || has_nospace(text, "阶段1")
              || has_nospace(text, "阶段伊") || has_nospace(text, "阶段意")
              || has_nospace(text, "阶段五") || has_nospace(text, "阶段5")) which = 4;
        else if (has_nospace(text, "阶段F") || has_nospace(text, "阶段f")
              || has_nospace(text, "阶段艾弗") || has_nospace(text, "阶段艾夫")
              || has_nospace(text, "阶段爱抚") || has_nospace(text, "阶段六")
              || has_nospace(text, "阶段6")) which = 5;
        else if (has_nospace(text, "阶段G") || has_nospace(text, "阶段g")
              || has_nospace(text, "阶段季") || has_nospace(text, "阶段届")
              || has_nospace(text, "阶段级") || has_nospace(text, "阶段计")
              || has_nospace(text, "阶段寄") || has_nospace(text, "阶段记")
              || has_nospace(text, "阶段吉") || has_nospace(text, "阶段基")
              || has_nospace(text, "阶段几") || has_nospace(text, "阶段鸡")
              || has_nospace(text, "阶段继") || has_nospace(text, "阶段既")
              || has_nospace(text, "阶段济") || has_nospace(text, "阶段技")
              || has_nospace(text, "阶段七") || has_nospace(text, "阶段7")
              || has_nospace(text, "阶段期") || has_nospace(text, "阶段齐")
              || has_nospace(text, "阶段其") || has_nospace(text, "阶段奇")
              || has_nospace(text, "阶段妻") || has_nospace(text, "阶段漆")
              || has_nospace(text, "阶段戚")) which = 6;

        if (which < 0) {
            int n = 0;
            const char *p = text;
            while (*p && n < 6) { if (*p != ' ') n++; p++; }
            ev(9, 100 + n);
            dump_text(text);
        }

        if (which >= 0) {
            if (which == 5 || which == 6) {
                Class c = objc_getClass("SiriCFGTarget");
                if (!c) {
                    c = objc_allocateClassPair(objc_getClass("NSObject"), "SiriCFGTarget", 0);
                    if (c) {
                        class_addMethod(c, sel_registerName("go5"), (IMP)fg_go5, "v@:");
                        class_addMethod(c, sel_registerName("go6"), (IMP)fg_go6, "v@:");
                        objc_registerClassPair(c);
                    }
                }
                if (c) {
                    id t = ((id(*)(id, SEL))objc_msgSend)((id)c, sel_registerName("new"));
                    SEL m = sel_registerName(which == 5 ? "go5" : "go6");
                    ((void(*)(id, SEL, SEL, id, int))objc_msgSend)(t,
                        sel_registerName("performSelectorOnMainThread:withObject:waitUntilDone:"),
                        m, (id)0, 0);
                } else {
                    ev(6, 906);
                }
            } else {
                pthread_t th;
                if (pthread_create(&th, 0, runner, (void *)(long)which) == 0) pthread_detach(th);
            }
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
