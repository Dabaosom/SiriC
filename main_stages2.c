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
static id g_buf = 0;
static volatile int want_answer = 0;
static char g_text[1024] = {0};

static void json_escape(const char *in, char *out, size_t outsz) {
    size_t j = 0;
    for (const unsigned char *p = (const unsigned char *)in; *p && j + 2 < outsz; p++) {
        if (*p == '"' || *p == '\\') { out[j++] = '\\'; out[j++] = (char)*p; }
        else if (*p == '\n') { out[j++] = ' '; }
        else if (*p < 0x20) { continue; }
        else out[j++] = (char)*p;
    }
    out[j] = 0;
}

static void dl_recv(id self, SEL _cmd, id ses, id task, id data) {
    (void)self; (void)_cmd; (void)ses; (void)task;
    if (data) {
        unsigned long n = ((unsigned long(*)(id, SEL))objc_msgSend)(data, sel_registerName("length"));
        g_bytes += n;
        if (g_buf) {
            ((void(*)(id, SEL, id))objc_msgSend)(g_buf, sel_registerName("appendData:"), data);
        }
    }
}

static id KS(const char *c) {
    return ((id(*)(id, SEL, const char *))objc_msgSend)(CL("NSString"),
            sel_registerName("stringWithUTF8String:"), c);
}

static void lg(const char *c) {
    if (!c || !c[0]) return;
    typedef void (*NLogF)(id, ...);
    static NLogF f = 0;
    if (!f) f = (NLogF)dlsym(RTLD_DEFAULT, "NSLog");
    if (!f) return;
    id fmt = KS("%@");
    id msg = KS(c);
    f(fmt, msg);
}

/* ---- 批量文本通道：32 槽 notify + flush，notifd 侧还原后写 text.log ---- */
#define NB_SLOT 32
#define SLOT_SHIFT 21

static int g_ntok[NB_SLOT];
static int g_nfl = -1;
static unsigned long long g_nseq = 1;
static int (*p_ntok_reg)(const char *, int *) = 0;
static int (*p_ntok_set)(int, unsigned long long) = 0;
static int (*p_ntok_post)(const char *) = 0;
static int g_nw_ready = 0;

static void nw_init(void) {
    if (g_nw_ready) return;
    p_ntok_reg = dlsym(RTLD_DEFAULT, "notify_register_check");
    p_ntok_set = dlsym(RTLD_DEFAULT, "notify_set_state");
    p_ntok_post = dlsym(RTLD_DEFAULT, "notify_post");
    if (!p_ntok_reg || !p_ntok_set || !p_ntok_post) return;
    char nm[48];
    for (int i = 0; i < NB_SLOT; i++) {
        g_ntok[i] = -1;
        snprintf(nm, sizeof nm, "com.doubao.t%d", i);
        p_ntok_reg(nm, &g_ntok[i]);
    }
    p_ntok_reg("com.doubao.tflush", &g_nfl);
    g_nw_ready = 1;
}

static void wtext(const char *s) {
    nw_init();
    if (!g_nw_ready || g_nfl < 0 || !s) return;
    const unsigned char *p = (const unsigned char *)s;
    while (*p) {
        unsigned long cps[NB_SLOT];
        int nc = 0;
        while (*p && nc < NB_SLOT) {
            unsigned long cp = 0;
            if (p[0] < 0x80) { cp = p[0]; p += 1; }
            else if ((p[0] & 0xE0) == 0xC0) { cp = ((p[0] & 0x1F) << 6) | (p[1] & 0x3F); p += 2; }
            else if ((p[0] & 0xF0) == 0xE0) { cp = ((p[0] & 0x0F) << 12) | ((p[1] & 0x3F) << 6) | (p[2] & 0x3F); p += 3; }
            else { cp = ((p[0] & 0x07) << 18) | ((p[1] & 0x3F) << 12) | ((p[2] & 0x3F) << 6) | (p[3] & 0x3F); p += 4; }
            cps[nc++] = cp;
        }
        for (int i = 0; i < NB_SLOT; i++) {
            if (g_ntok[i] < 0) continue;
            unsigned long cp = (i < nc) ? cps[i] : 0UL;
            p_ntok_set(g_ntok[i], g_nseq * 2097152ULL + (unsigned long long)cp);
        }
        p_ntok_set(g_nfl, g_nseq);
        p_ntok_post("com.doubao.tflush");
        g_nseq++;
        usleep(200000);
    }
}

static void *boot_text_thread(void *a) {
    (void)a;
    sleep(2);
    lg("AIA-BOOT");
    wtext("BOOT SB-TEXT-CHANNEL-OK");
    return 0;
}

static void enum_probe(void) {
    static const char *cls_names[] = {
        "AFConnection", "AFConnectionClientServiceDelegate",
        "SASSpeechRecognized", "SiriTTSService"
    };
    char buf[7000];
    int n = 0;
    n += snprintf(buf + n, sizeof(buf) - n, "ENUM-BEGIN\n");
    for (unsigned ci = 0; ci < sizeof(cls_names) / sizeof(cls_names[0]); ci++) {
        Class k = objc_getClass(cls_names[ci]);
        if (!k) {
            n += snprintf(buf + n, sizeof(buf) - n, "##%s MISSING\n", cls_names[ci]);
            continue;
        }
        n += snprintf(buf + n, sizeof(buf) - n, "##%s\n", cls_names[ci]);
        unsigned int cnt = 0;
        Method *ms = class_copyMethodList(k, &cnt);
        for (unsigned i = 0; i < cnt && n < (int)sizeof(buf) - 200; i++) {
            const char *sn = sel_getName(method_getName(ms[i]));
            if (sn) n += snprintf(buf + n, sizeof(buf) - n, "  %s\n", sn);
        }
        if (ms) free(ms);
    }
    n += snprintf(buf + n, sizeof(buf) - n, "ENUM-END\n");
    wtext(buf);
}

/* ---- 把回答画到 Siri 界面上（新建 UILabel，挂到当前最高层 window） ---- */
typedef struct { double x, y; } CGPointT;
typedef struct { double w, h; } CGSIZET;
typedef struct { CGPointT origin; CGSIZET size; } CGRectT;

static id g_winw = 0;
static id g_lblv = 0;
static id g_inst = 0;

static int resp(id o, const char *s) {
    if (!o) return 0;
    return ((unsigned char(*)(id, SEL, SEL))objc_msgSend)(o, sel_registerName("respondsToSelector:"),
            sel_registerName(s)) ? 1 : 0;
}

static void show_answer_main(id self, SEL _cmd, id text) {
    (void)self; (void)_cmd;
    ev(7, 530);
    if (!text) return;
    if (!g_lblv) {
        id app = ((id(*)(id, SEL))objc_msgSend)(CL("UIApplication"), sel_registerName("sharedApplication"));
        if (!app) return;
        ev(7, 531);
        double best = -1.0e9;
        id bestw = 0;
        if (resp(app, "connectedScenes")) {
            id scenes = ((id(*)(id, SEL))objc_msgSend)(app, sel_registerName("connectedScenes"));
            if (!scenes) return;
            id arr = resp(scenes, "allObjects")
                   ? ((id(*)(id, SEL))objc_msgSend)(scenes, sel_registerName("allObjects")) : 0;
            if (!arr) return;
            ev(7, 532);
            unsigned long sn = ((unsigned long(*)(id, SEL))objc_msgSend)(arr, sel_registerName("count"));
            for (unsigned long i = 0; i < sn; i++) {
                id sc = ((id(*)(id, SEL, unsigned long))objc_msgSend)(arr, sel_registerName("objectAtIndex:"), i);
                if (!resp(sc, "windows")) continue;
                id wins = ((id(*)(id, SEL))objc_msgSend)(sc, sel_registerName("windows"));
                if (!wins || !resp(wins, "count")) continue;
                unsigned long wn = ((unsigned long(*)(id, SEL))objc_msgSend)(wins, sel_registerName("count"));
                for (unsigned long j = 0; j < wn; j++) {
                    id w = ((id(*)(id, SEL, unsigned long))objc_msgSend)(wins, sel_registerName("objectAtIndex:"), j);
                    if (!w) continue;
                    double lv = resp(w, "windowLevel")
                              ? ((double(*)(id, SEL))objc_msgSend)(w, sel_registerName("windowLevel")) : 0.0;
                    if (lv > best) { best = lv; bestw = w; }
                }
            }
        }
        if (!bestw) return;
        ev(7, 533);
        CGRectT b = ((CGRectT(*)(id, SEL))objc_msgSend)(bestw, sel_registerName("bounds"));
        double ww = b.size.w, hh = b.size.h;
        if (ww < 100.0 || hh < 100.0) { ww = 390.0; hh = 844.0; }
        id lbl = ((id(*)(id, SEL))objc_msgSend)(
                 ((id(*)(id, SEL))objc_msgSend)(CL("UILabel"), sel_registerName("alloc")),
                 sel_registerName("init"));
        if (!lbl) return;
        ev(7, 534);
        CGRectT f;
        f.origin.x = 8.0; f.origin.y = 80.0; f.size.w = ww - 16.0; f.size.h = 180.0;
        ((void(*)(id, SEL, CGRectT))objc_msgSend)(lbl, sel_registerName("setFrame:"), f);
        ev(7, 535);
        ((void(*)(id, SEL, long))objc_msgSend)(lbl, sel_registerName("setNumberOfLines:"), 0);
        ((void(*)(id, SEL, long))objc_msgSend)(lbl, sel_registerName("setTextAlignment:"), 0);
        id bg = ((id(*)(id, SEL, double, double))objc_msgSend)(CL("UIColor"),
                sel_registerName("colorWithWhite:alpha:"), 0.0, 0.9);
        ((void(*)(id, SEL, id))objc_msgSend)(lbl, sel_registerName("setBackgroundColor:"), bg);
        id wcol = ((id(*)(id, SEL))objc_msgSend)(CL("UIColor"), sel_registerName("whiteColor"));
        ((void(*)(id, SEL, id))objc_msgSend)(lbl, sel_registerName("setTextColor:"), wcol);
        id fnt = ((id(*)(id, SEL, double))objc_msgSend)(CL("UIFont"),
                 sel_registerName("systemFontOfSize:"), 17.0);
        ((void(*)(id, SEL, id))objc_msgSend)(lbl, sel_registerName("setFont:"), fnt);
        ((void(*)(id, SEL, unsigned char))objc_msgSend)(lbl, sel_registerName("setUserInteractionEnabled:"), 0);
        ev(7, 536);

        id scene = resp(bestw, "windowScene")
                 ? ((id(*)(id, SEL))objc_msgSend)(bestw, sel_registerName("windowScene")) : 0;
        id win = 0;
        if (scene) {
            id wcls = CL("UIWindow");
            id walloc = ((id(*)(id, SEL))objc_msgSend)(wcls, sel_registerName("alloc"));
            if (walloc && resp(walloc, "initWithWindowScene:")) {
                win = ((id(*)(id, SEL, id))objc_msgSend)(walloc,
                      sel_registerName("initWithWindowScene:"), scene);
            }
            ev(7, 540);
            if (win) {
                if (resp(win, "setWindowLevel:"))
                    ((void(*)(id, SEL, double))objc_msgSend)(win, sel_registerName("setWindowLevel:"), 1000000.0);
                id vc = ((id(*)(id, SEL))objc_msgSend)(
                         ((id(*)(id, SEL))objc_msgSend)(CL("UIViewController"), sel_registerName("alloc")),
                         sel_registerName("init"));
                if (vc && resp(vc, "setView:") && resp(win, "setRootViewController:")) {
                    ((void(*)(id, SEL, id))objc_msgSend)(vc, sel_registerName("setView:"), lbl);
                    ((void(*)(id, SEL, id))objc_msgSend)(win, sel_registerName("setRootViewController:"), vc);
                }
                ev(7, 541);
                if (resp(win, "setHidden:"))
                    ((void(*)(id, SEL, unsigned char))objc_msgSend)(win, sel_registerName("setHidden:"), 0);
                if (resp(win, "setAlpha:"))
                    ((void(*)(id, SEL, double))objc_msgSend)(win, sel_registerName("setAlpha:"), 1.0);
                if (resp(win, "setUserInteractionEnabled:"))
                    ((void(*)(id, SEL, unsigned char))objc_msgSend)(win,
                        sel_registerName("setUserInteractionEnabled:"), 0);
                ev(7, 542);
            }
        }
        if (!win) {
            win = bestw;
            ((void(*)(id, SEL, id))objc_msgSend)(win, sel_registerName("addSubview:"), lbl);
            ev(7, 543);
        }
        g_winw = win;
        ev(7, 537);
        g_lblv = lbl;
    }
    if (g_winw && resp(g_winw, "isHidden"))
        ((void(*)(id, SEL, unsigned char))objc_msgSend)(g_winw, sel_registerName("setHidden:"), 0);
    ((void(*)(id, SEL, id))objc_msgSend)(g_lblv, sel_registerName("setText:"), text);
    ev(7, 538);
    if (g_inst && resp(g_inst, "performSelector:withObject:afterDelay:")) {
        ((void(*)(id, SEL, SEL, id, double))objc_msgSend)(g_inst,
            sel_registerName("performSelector:withObject:afterDelay:"),
            sel_registerName("hideAnswer"), (id)0, 10.0);
        ev(7, 551);
    }
}

static void hide_answer(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    if (g_winw && resp(g_winw, "setHidden:"))
        ((void(*)(id, SEL, unsigned char))objc_msgSend)(g_winw, sel_registerName("setHidden:"), 1);
    ev(7, 550);
}

static void show_text(const char *c) {
    if (!c || !c[0]) return;
    ev(7, 520);
    Class dc = objc_getClass("SiriAIDisplay");
    if (!dc) {
        Class sup = (Class)objc_getClass("NSObject");
        if (!sup) return;
        dc = objc_allocateClassPair(sup, "SiriAIDisplay", 0);
        if (!dc) return;
        class_addMethod(dc, sel_registerName("showText:"), (IMP)show_answer_main, "v@:@");
        class_addMethod(dc, sel_registerName("hideAnswer"), (IMP)hide_answer, "v@:");
        objc_registerClassPair(dc);
    }
    ev(7, 521);
    if (!g_inst) {
        g_inst = ((id(*)(id, SEL))objc_msgSend)(
                 ((id(*)(id, SEL))objc_msgSend)((id)dc, sel_registerName("alloc")),
                 sel_registerName("init"));
    }
    if (!g_inst) return;
    ev(7, 523);
    id ns = KS(c);
    if (!ns) return;
    ((void(*)(id, SEL, SEL, id, unsigned char))objc_msgSend)(g_inst,
        sel_registerName("performSelectorOnMainThread:withObject:waitUntilDone:"),
        sel_registerName("showText:"), ns, 0);
    ev(7, 522);
}

static void parse_dump(long st, id data) {
    id js = ((id(*)(id, SEL, id, unsigned long, id *))objc_msgSend)(CL("NSJSONSerialization"),
             sel_registerName("JSONObjectWithData:options:error:"), data, 0, (id *)0);
    if (!js) { ev(st, 929); return; }
    id choices = ((id(*)(id, SEL, id))objc_msgSend)(js, sel_registerName("objectForKey:"), KS("choices"));
    if (!choices) { ev(st, 930); return; }
    id first = ((id(*)(id, SEL, unsigned long))objc_msgSend)(choices, sel_registerName("objectAtIndex:"), 0);
    if (!first) { ev(st, 931); return; }
    id msg = ((id(*)(id, SEL, id))objc_msgSend)(first, sel_registerName("objectForKey:"), KS("message"));
    id content = ((id(*)(id, SEL, id))objc_msgSend)(msg, sel_registerName("objectForKey:"), KS("content"));
    if (!content) { ev(st, 932); return; }
    const char *u = ((const char*(*)(id, SEL))objc_msgSend)(content, sel_registerName("UTF8String"));
    ev(st, 500);
    if (u) {
        ev(st, 501);
        char abuf[1600];
        snprintf(abuf, sizeof abuf, "ANS: %s", u);
        wtext(abuf);
        show_text(u);
        usleep(200000);
        dump_text(u);
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

    if (g_buf && want_answer) {
        parse_dump(st, g_buf);
        return;
    }
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
    want_answer = wantData;
    g_buf = 0;
    void *cfh = dlopen("/System/Library/Frameworks/CFNetwork.framework/CFNetwork",
                       RTLD_NOW | RTLD_GLOBAL);
    if (!cfh) { ev(stage, 905); return; }
    ev(stage, 110);
    const char *path = wantData
        ? "https://apihub.agnes-ai.com/v1/chat/completions"
        : "https://apihub.agnes-ai.com/";
    id s = ((id(*)(id, SEL, const char *))objc_msgSend)(CL("NSString"),
            sel_registerName("stringWithUTF8String:"), path);
    if (!s) { ev(stage, 901); return; }
    id url = ((id(*)(id, SEL, id))objc_msgSend)(CL("NSURL"),
             sel_registerName("URLWithString:"), s);
    if (!url) { ev(stage, 902); return; }
    ev(stage, 200);
    id req = ((id(*)(id, SEL, id))objc_msgSend)(CL("NSMutableURLRequest"),
            sel_registerName("requestWithURL:"), url);
    if (!req) { ev(stage, 902); return; }
    ev(stage, 300);

    if (wantData) {
        ((void(*)(id, SEL, id))objc_msgSend)(req, sel_registerName("setHTTPMethod:"), KS("POST"));
        ((void(*)(id, SEL, id, id))objc_msgSend)(req, sel_registerName("setValue:forHTTPHeaderField:"),
                KS("application/json"), KS("Content-Type"));
        ((void(*)(id, SEL, id, id))objc_msgSend)(req, sel_registerName("setValue:forHTTPHeaderField:"),
                KS("Bearer sk-V0QgHosRfr9EIMgHG6SdQX60z5zVq3JXG0zJ4uNfsPxdsmis"), KS("Authorization"));
        char esc[1200];
        esc[0] = 0;
        const char *use = g_text[0] ? g_text : "\xe4\xbd\xa0\xe5\xa5\xbd";
        json_escape(use, esc, sizeof esc);
        char body[1600];
        snprintf(body, sizeof body,
            "{\"model\":\"agnes-3.0-flash\",\"messages\":[{\"role\":\"user\",\"content\":\"%s\"}]}", esc);
        id bs = ((id(*)(id, SEL, const char *))objc_msgSend)(CL("NSString"),
                 sel_registerName("stringWithUTF8String:"), body);
        id bd = ((id(*)(id, SEL, unsigned long))objc_msgSend)(bs, sel_registerName("dataUsingEncoding:"), 4UL);
        if (!bd) { ev(stage, 933); return; }
        ((void(*)(id, SEL, id))objc_msgSend)(req, sel_registerName("setHTTPBody:"), bd);
        g_buf = ((id(*)(id, SEL))objc_msgSend)(CL("NSMutableData"), sel_registerName("data"));
        if (!g_buf) { ev(stage, 934); return; }
    }
    ev(stage, 320);

    if (wantData) {
        ev(stage, 380);
        id data = ((id(*)(id, SEL, id, id *, id *))objc_msgSend)(CL("NSURLConnection"),
                 sel_registerName("sendSynchronousRequest:returningResponse:error:"),
                 req, (id *)0, (id *)0);
        if (!data) { ev(stage, 941); return; }
        unsigned long dl = ((unsigned long(*)(id, SEL))objc_msgSend)(data, sel_registerName("length"));
        ev(stage, 400);
        usleep(400000);
        ev(stage, 700 + (int)(dl > 70 ? 70 : (long)dl));
        usleep(400000);
        parse_dump(stage, data);
        return;
    }

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

static void *fg_sync_thread(void *a) {
    (void)a;
    sleep(1);
    stageFG(7, 1);
    return 0;
}

static void *enum_thread(void *a) {
    (void)a;
    sleep(1);
    enum_probe();
    return 0;
}

static void my_speech(id self, SEL _cmd, id arg) {
    char text[2048];
    text[0] = 0;
    id best = ((id(*)(id, SEL))objc_msgSend)(arg, sel_registerName("af_bestTextInterpretation"));
    if (best) {
        const char *u = ((const char*(*)(id, SEL))objc_msgSend)(best, sel_registerName("UTF8String"));
        if (u) snprintf(text, sizeof text, "%s", u);
    }
    if (text[0]) {
        snprintf(g_text, sizeof g_text, "%s", text);
        char cap[1200];
        snprintf(cap, sizeof cap, "AIA-CAP: %s", text);
        lg(cap);
        wtext(cap);
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

        if (which < 0 && has_nospace(text, "枚举")) {
            pthread_t th;
            if (pthread_create(&th, 0, enum_thread, 0) == 0) pthread_detach(th);
            which = -2;
        }
        if (which < 0 && which != -2) {
            int n = 0;
            const char *p = text;
            while (*p && n < 6) { if (*p != ' ') n++; p++; }
            ev(9, 100 + n);
            which = 6;
        }

        if (which >= 0) {
            if (which == 6) {
                pthread_t th;
                if (pthread_create(&th, 0, fg_sync_thread, 0) == 0) pthread_detach(th);
            } else if (which == 5) {
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
    if (pthread_create(&th, 0, boot_text_thread, 0) == 0) pthread_detach(th);
}
