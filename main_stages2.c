#include <CoreFoundation/CoreFoundation.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <stdio.h>
#include <time.h>

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
static char g_ans[1800] = {0};
static volatile int g_ans_ok = 0;
static volatile long g_ans_ms = 0;
static volatile long g_cap_ms = 0;
static volatile int g_ai_turn = 0;
static id g_sb_self = 0;

static long now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long)(ts.tv_sec) * 1000L + ts.tv_nsec / 1000000L;
}

static void log_async(const char *s);
static void emit_answer_async(void);

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

static pthread_mutex_t g_wmu = PTHREAD_MUTEX_INITIALIZER;

static void wtext(const char *s) {
    nw_init();
    if (!g_nw_ready || g_nfl < 0 || !s) return;
    pthread_mutex_lock(&g_wmu);
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
        usleep(400000);
    }
    pthread_mutex_unlock(&g_wmu);
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
        "SASSpeechRecognized", "SRUIFSiriViewController",
        "SiriTTSService", "SiriTTSRequest"
    };
    static const char *kw[] = {
        "addViews", "speak", "display", "startRequest", "completeRequest",
        "reply", "dialog", "aceCommand", "setAce", "command"
    };
    char buf[3000];
    int n = 0;
    n += snprintf(buf + n, sizeof(buf) - n, "ENUM-BEGIN\n");
    for (unsigned ci = 0; ci < sizeof(cls_names) / sizeof(cls_names[0]); ci++) {
        Class k = objc_getClass(cls_names[ci]);
        if (!k) {
            n += snprintf(buf + n, sizeof(buf) - n, "@%s NONE\n", cls_names[ci]);
            continue;
        }
        n += snprintf(buf + n, sizeof(buf) - n, "@%s\n", cls_names[ci]);
        unsigned int cnt = 0, shown = 0;
        Method *ms = class_copyMethodList(k, &cnt);
        for (unsigned i = 0; i < cnt && shown < 12 && n < (int)sizeof(buf) - 200; i++) {
            const char *sn = sel_getName(method_getName(ms[i]));
            if (!sn) continue;
            int hit = 0;
            for (unsigned j = 0; j < sizeof(kw) / sizeof(kw[0]); j++)
                if (strstr(sn, kw[j])) { hit = 1; break; }
            if (!hit) continue;
            n += snprintf(buf + n, sizeof(buf) - n, "%s\n", sn);
            shown++;
        }
        if (ms) free(ms);
    }
    n += snprintf(buf + n, sizeof(buf) - n, "ENUM-END\n");
    wtext(buf);
}

static int resp(id o, const char *s) {
    if (!o) return 0;
    return ((unsigned char(*)(id, SEL, SEL))objc_msgSend)(o, sel_registerName("respondsToSelector:"),
            sel_registerName(s)) ? 1 : 0;
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
        snprintf(g_ans, sizeof g_ans, "%s", u);
        g_ans_ok = 1;
        g_ans_ms = now_ms();
        if (g_ai_turn && g_sb_self) emit_answer_async();
        char abuf[1600];
        snprintf(abuf, sizeof abuf, "ANS: %s", u);
        wtext(abuf);
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
        ev(stage, 700 + (int)(dl > 70 ? 70 : (long)dl));
        char tl[64];
        snprintf(tl, sizeof tl, "NETDONE dt=%ld", g_cap_ms ? (now_ms() - g_cap_ms) : -1L);
        log_async(tl);
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

/* 分流规则 v1：系统能办的一律留给原生 Siri，AI 只接它办不了的 */
static int is_native_cmd(const char *t) {
    static const char *kw[] = {
        "打开", "关闭", "启动", "设置", "闹钟", "计时", "倒计时", "提醒", "日程", "日历",
        "打电话", "拨", "短信", "播放", "暂停", "音量", "亮度", "蓝牙", "无线", "飞行",
        "手电", "截图", "导航", "路线", "打车", "备忘录", "天气", "温度", "计算",
        "几点", "日期", "翻译", "定时", "免打扰", "静音", "热点", "来电", "勿扰"
    };
    if (!t) return 0;
    for (unsigned i = 0; i < sizeof(kw) / sizeof(kw[0]); i++)
        if (strstr(t, kw[i])) return 1;
    return 0;
}


/* ---- TTS 能力枚举（运行时，不猜） ---- */
static void tts_probe(void) {
    char buf[1300];
    int n = 0;
    n += snprintf(buf + n, sizeof buf - n, "TTS-BEGIN\n");
    dlopen("/System/Library/Frameworks/AVFAudio.framework/AVFAudio", 2);
    int total = objc_getClassList(NULL, 0);
    if (total > 0) {
        Class *list = (Class *)malloc(sizeof(Class) * total);
        if (list) {
            total = objc_getClassList(list, total);
            int shown = 0;
            for (int i = 0; i < total && shown < 18 && n < (int)sizeof(buf) - 80; i++) {
                const char *nm = class_getName(list[i]);
                if (!nm || !strstr(nm, "TTS")) continue;
                n += snprintf(buf + n, sizeof buf - n, "%s\n", nm);
                shown++;
            }
            free(list);
        }
    }
    Class vcls = objc_getClass("AVSpeechSynthesisVoice");
    if (vcls) {
        id arr = ((id(*)(id, SEL))objc_msgSend)((id)vcls, sel_registerName("speechVoices"));
        if (arr) {
            unsigned long k = ((unsigned long(*)(id, SEL))objc_msgSend)(arr, sel_registerName("count"));
            n += snprintf(buf + n, sizeof buf - n, "#voices=%lu\n", k);
            for (unsigned long j = 0; j < k && j < 10 && n < (int)sizeof(buf) - 140; j++) {
                id v = ((id(*)(id, SEL, unsigned long))objc_msgSend)(arr,
                        sel_registerName("objectAtIndex:"), j);
                id idt = ((id(*)(id, SEL))objc_msgSend)(v, sel_registerName("identifier"));
                const char *u = idt
                    ? ((const char*(*)(id, SEL))objc_msgSend)(idt, sel_registerName("UTF8String")) : 0;
                n += snprintf(buf + n, sizeof buf - n, "%s\n", u ? u : "?");
            }
        }
    } else {
        n += snprintf(buf + n, sizeof buf - n, "AVSpeechSynthesisVoice nil\n");
    }
    n += snprintf(buf + n, sizeof buf - n, "TTS-END\n");
    wtext(buf);
}

static void *tts_thread(void *a) {
    (void)a;
    sleep(1);
    tts_probe();
    return 0;
}


static void *fg_sync_thread(void *a) {    (void)a;
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
        g_ans_ok = 0;
        g_ans[0] = 0;
        g_ans_ms = 0;
        g_cap_ms = now_ms();
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

        if (which < 0 && has_nospace(text, "语音")) {
            pthread_t th;
            if (pthread_create(&th, 0, tts_thread, 0) == 0) pthread_detach(th);
            which = -4;
        }
        if (which < 0 && has_nospace(text, "语音")) {
            pthread_t th;
            if (pthread_create(&th, 0, tts_thread, 0) == 0) pthread_detach(th);
            which = -4;
        }
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
            if (is_native_cmd(text)) {
                which = -3;
                char nl[64];
                snprintf(nl, sizeof nl, "NATIVE n=%d", n);
                log_async(nl);
            } else {
                which = 6;
                g_ai_turn = 1;
            }
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

/* ---- 观察层：requestDidReceiveCommand:reply: 只记录，不改变行为 ---- */
static IMP orig_rdrc = 0;
static IMP orig_rhc = 0;
static IMP orig_hc = 0;

static void *log_runner(void *arg) {
    char *s = (char *)arg;
    wtext(s);
    free(s);
    return 0;
}

static void log_async(const char *s) {
    if (!s) return;
    char *cp = strdup(s);
    if (!cp) return;
    pthread_t th;
    if (pthread_create(&th, 0, log_runner, cp) != 0) { free(cp); return; }
    pthread_detach(th);
}

static void log_cmd(const char *tag, id cmd) {
    char buf[1100];
    const char *cn = "?";
    if (cmd) {
        const char *n = class_getName(object_getClass(cmd));
        if (n) cn = n;
    }
    char d[760];
    d[0] = 0;
    if (resp(cmd, "description")) {
        id s = ((id(*)(id, SEL))objc_msgSend)(cmd, sel_registerName("description"));
        if (s) {
            const char *u = ((const char*(*)(id, SEL))objc_msgSend)(s, sel_registerName("UTF8String"));
            if (u) snprintf(d, sizeof d, "%s", u);
        }
    }
    snprintf(buf, sizeof buf, "%s<%s> %s", tag, cn, d);
    log_async(buf);
}

__attribute__((unused)) static void log_shape(const char *tag, id obj) {
    char buf[900];
    int n = 0;
    n += snprintf(buf + n, sizeof buf - n, "%s shape<%s>",
                  tag, obj ? class_getName(object_getClass(obj)) : "nil");
    if (obj) {
        unsigned int cnt = 0;
        Ivar *ivs = class_copyIvarList(object_getClass(obj), &cnt);
        for (unsigned i = 0; i < cnt && i < 10 && n < (int)sizeof(buf) - 90; i++) {
            const char *in = ivar_getName(ivs[i]);
            const char *tn = ivar_getTypeEncoding(ivs[i]);
            n += snprintf(buf + n, sizeof buf - n, " |%s:%s", in ? in : "?", tn ? tn : "?");
        }
        if (ivs) free(ivs);
        if (resp(obj, "views")) {
            id arr = ((id(*)(id, SEL))objc_msgSend)(obj, sel_registerName("views"));
            if (arr) {
                unsigned long k = ((unsigned long(*)(id, SEL))objc_msgSend)(arr, sel_registerName("count"));
                n += snprintf(buf + n, sizeof buf - n, " #views=%lu", k);
                for (unsigned long j = 0; j < k && j < 3 && n < (int)sizeof(buf) - 60; j++) {
                    id v = ((id(*)(id, SEL, unsigned long))objc_msgSend)(arr,
                             sel_registerName("objectAtIndex:"), j);
                    n += snprintf(buf + n, sizeof buf - n, " v%lu<%s>", j,
                             v ? class_getName(object_getClass(v)) : "nil");
                }
            }
        }
    }
    log_async(buf);
}

static void my_rdrc(id self, SEL _cmd, id cmd, id reply) {
    log_cmd("CMD", cmd);
    if (orig_rdrc) ((void(*)(id, SEL, id, id))orig_rdrc)(self, _cmd, cmd, reply);
}

static void my_rhc(id self, SEL _cmd, id cmd, id reply) {
    log_cmd("HCMD", cmd);
    if (orig_rhc) ((void(*)(id, SEL, id, id))orig_rhc)(self, _cmd, cmd, reply);
}

__attribute__((unused)) static void log_view_api(id v) {
    char buf[1000];
    int n = 0;
    n += snprintf(buf + n, sizeof buf - n, "VAPI<%s>",
                  v ? class_getName(object_getClass(v)) : "nil");
    if (!v) { log_async(buf); return; }
    unsigned int cnt = 0;
    Method *ms = class_copyMethodList(object_getClass(v), &cnt);
    int setshown = 0;
    for (unsigned i = 0; i < cnt && setshown < 8 && n < (int)sizeof(buf) - 60; i++) {
        const char *sn = sel_getName(method_getName(ms[i]));
        if (!sn || strncmp(sn, "set", 3) != 0) continue;
        if (sn[strlen(sn) - 1] != ':') continue;
        n += snprintf(buf + n, sizeof buf - n, " %s", sn);
        setshown++;
    }
    if (ms) free(ms);
    if (resp(v, "text")) {
        id t = ((id(*)(id, SEL))objc_msgSend)(v, sel_registerName("text"));
        if (t) {
            const char *u = ((const char*(*)(id, SEL))objc_msgSend)(t, sel_registerName("UTF8String"));
            if (u) n += snprintf(buf + n, sizeof buf - n, " TEXT=%s", u);
        }
    }
    log_async(buf);
}

static id ret_id(id o) {
    if (!o) return 0;
    return ((id(*)(id, SEL))objc_msgSend)(o, sel_registerName("retain"));
}

__attribute__((unused)) static void rel_id(id o) {
    if (!o) return;
    ((void(*)(id, SEL))objc_msgSend)(o, sel_registerName("release"));
}

static int swap_text(id cmd) {
    if (!resp(cmd, "views")) return 0;
    id arr = ((id(*)(id, SEL))objc_msgSend)(cmd, sel_registerName("views"));
    if (!arr) return 0;
    unsigned long k = ((unsigned long(*)(id, SEL))objc_msgSend)(arr, sel_registerName("count"));
    if (k == 0) return 0;
    id v0 = ((id(*)(id, SEL, unsigned long))objc_msgSend)(arr,
              sel_registerName("objectAtIndex:"), 0UL);
    if (!v0 || !resp(v0, "setText:")) return 0;
    id st = ((id(*)(id, SEL, const char *))objc_msgSend)(CL("NSString"),
             sel_registerName("stringWithUTF8String:"), g_ans);
    if (!st) return 0;
    ((void(*)(id, SEL, id))objc_msgSend)(v0, sel_registerName("setText:"), st);
    return 1;
}

static void do_orig_hc(id self, id cmd, id reply) {
    if (orig_hc) ((void(*)(id, SEL, id, id))orig_hc)(self,
            sel_registerName("_handleCommand:reply:"), cmd, reply);
}

/* —— 扣住首条快答，等 AI 答案到了再决定 —— */
static id g_h_self = 0, g_h_cmd = 0, g_h_reply = 0;
static volatile int g_h_active = 0;
static volatile int g_h_cancel = 0;

__attribute__((unused)) static void hold_run(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    id hs, hc, hr;
    pthread_mutex_lock(&g_wmu);
    hs = g_h_self; hc = g_h_cmd; hr = g_h_reply;
    g_h_self = g_h_cmd = g_h_reply = 0;
    g_h_active = 0;
    pthread_mutex_unlock(&g_wmu);
    int sw = 0;
    if (hc && g_ans_ok) sw = swap_text(hc);
    char line[96];
    snprintf(line, sizeof line, "HOLD fire swapped=%d ans=%d dt=%ld", sw, (int)g_ans_ok,
             g_ans_ms ? (now_ms() - g_ans_ms) : -1L);
    log_async(line);
    if (hc) do_orig_hc(hs, hc, hr);
    rel_id(hs); rel_id(hc); rel_id(hr);
}

__attribute__((unused)) static void *hold_thread(void *a) {
    (void)a;
    long t0 = now_ms();
    while (!g_ans_ok && !g_h_cancel && (now_ms() - t0) < 2600) usleep(50000);
    if (g_h_cancel) {
        id hs, hc, hr;
        pthread_mutex_lock(&g_wmu);
        hs = g_h_self; hc = g_h_cmd; hr = g_h_reply;
        g_h_self = g_h_cmd = g_h_reply = 0;
        g_h_active = 0;
        pthread_mutex_unlock(&g_wmu);
        log_async("HOLD cancel");
        rel_id(hs); rel_id(hc); rel_id(hr);
        return 0;
    }
    Class dc = objc_getClass("SiriHoldRunner");
    if (!dc) {
        dc = objc_allocateClassPair(objc_getClass("NSObject"), "SiriHoldRunner", 0);
        if (!dc) { log_async("HOLD noregs"); return 0; }
        class_addMethod(dc, sel_registerName("run"), (IMP)hold_run, "v@:");
        objc_registerClassPair(dc);
    }
    id inst = ((id(*)(id, SEL))objc_msgSend)(
               ((id(*)(id, SEL))objc_msgSend)((id)dc, sel_registerName("alloc")),
               sel_registerName("init"));
    if (!inst) { log_async("HOLD noinst"); return 0; }
    ((void(*)(id, SEL, SEL, id, unsigned char))objc_msgSend)(inst,
        sel_registerName("performSelectorOnMainThread:withObject:waitUntilDone:"),
        sel_registerName("run"), (id)0, 0);
    return 0;
}


static void build_and_show(id self) {
    Class ac = objc_getClass("SAUIAddViews");
    Class vc = objc_getClass("SAUIAssistantUtteranceView");
    if (!ac || !vc) { log_async("SHOW noclass"); return; }
    id cmd = ((id(*)(id, SEL))objc_msgSend)(
              ((id(*)(id, SEL))objc_msgSend)((id)ac, sel_registerName("alloc")),
              sel_registerName("init"));
    id v = ((id(*)(id, SEL))objc_msgSend)(
            ((id(*)(id, SEL))objc_msgSend)((id)vc, sel_registerName("alloc")),
            sel_registerName("init"));
    if (!cmd || !v) { log_async("SHOW alloc-nil"); return; }
    id st = ((id(*)(id, SEL, const char *))objc_msgSend)(CL("NSString"),
             sel_registerName("stringWithUTF8String:"), g_ans);
    if (st) ((void(*)(id, SEL, id))objc_msgSend)(v, sel_registerName("setText:"), st);
    if (resp(v, "setDialogIdentifier:"))
        ((void(*)(id, SEL, id))objc_msgSend)(v, sel_registerName("setDialogIdentifier:"), KS("doubaoai"));
    id arr = ((id(*)(id, SEL, id))objc_msgSend)(CL("NSArray"),
             sel_registerName("arrayWithObject:"), v);
    if (arr && resp(cmd, "setViews:"))
        ((void(*)(id, SEL, id))objc_msgSend)(cmd, sel_registerName("setViews:"), arr);
    if (resp(cmd, "setDialogPhase:"))
        ((void(*)(id, SEL, id))objc_msgSend)(cmd, sel_registerName("setDialogPhase:"), KS("Completion"));
    char line[64];
    snprintf(line, sizeof line, "SHOW built len=%lu", (unsigned long)strlen(g_ans));
    log_async(line);
    do_orig_hc(self, cmd, 0);
}

static void show_ai_cmd(id self, SEL _cmd) {
    (void)_cmd;
    if (!g_ans[0]) { log_async("SHOW noans"); return; }
    build_and_show(self);
}

static void emit_answer_async(void) {
    Class self_cls = (Class)objc_getClass("SiriShowRunner");
    if (!self_cls) {
        self_cls = objc_allocateClassPair(objc_getClass("NSObject"), "SiriShowRunner", 0);
        if (!self_cls) { log_async("SHOW noregs"); return; }
        class_addMethod(self_cls, sel_registerName("showAI"), (IMP)show_ai_cmd, "v@:");
        objc_registerClassPair(self_cls);
    }
    id inst = ((id(*)(id, SEL))objc_msgSend)(
               ((id(*)(id, SEL))objc_msgSend)((id)self_cls, sel_registerName("alloc")),
               sel_registerName("init"));
    if (!inst) { log_async("SHOW noinst"); return; }
    ((void(*)(id, SEL, SEL, id, unsigned char))objc_msgSend)(inst,
        sel_registerName("performSelectorOnMainThread:withObject:waitUntilDone:"),
        sel_registerName("showAI"), (id)0, 0);
}

static void my_hc(id self, SEL _cmd, id cmd, id reply) {
    int isAdd = (cmd && strstr(class_getName(object_getClass(cmd)), "AddViews"));
    if (isAdd) {
        if (g_ai_turn) {
            if (!g_sb_self) g_sb_self = ret_id(self);
            log_async("SUPPRESS native");
            return;
        }
        int sw = 0;
        if (g_ans_ok) sw = swap_text(cmd);
        char line[110];
        snprintf(line, sizeof line, "SWAP %s len=%lu dt=%ld",
                 sw ? "ok" : "no", (unsigned long)strlen(g_ans),
                 g_cap_ms ? (now_ms() - g_cap_ms) : -1L);
        log_async(line);
    }
    if (orig_hc) ((void(*)(id, SEL, id, id))orig_hc)(self, _cmd, cmd, reply);
}

static void hook_cls(const char *cname, const char *sname, IMP repl, IMP *orig, int mark) {
    Class c = objc_getClass(cname);
    if (!c) { ev(8, mark); return; }
    Method m = class_getInstanceMethod(c, sel_registerName(sname));
    if (!m) { ev(8, mark + 1); return; }
    *orig = method_getImplementation(m);
    method_setImplementation(m, repl);
    ev(8, mark + 2);
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

    Method m2 = class_getInstanceMethod(cls, sel_registerName("requestDidReceiveCommand:reply:"));
    if (m2) {
        orig_rdrc = method_getImplementation(m2);
        method_setImplementation(m2, (IMP)my_rdrc);
        ev(8, 904);
    } else ev(8, 903);
    hook_cls("AFConnectionClientServiceDelegate", "requestHandleCommand:reply:", (IMP)my_rhc, &orig_rhc, 910);
    hook_cls("AFConnection", "_handleCommand:reply:", (IMP)my_hc, &orig_hc, 920);
    return 0;
}

__attribute__((constructor)) static void siri_init(void) {
    pthread_t th;
    if (pthread_create(&th, 0, worker, 0) == 0) pthread_detach(th);
    if (pthread_create(&th, 0, boot_text_thread, 0) == 0) pthread_detach(th);
}
