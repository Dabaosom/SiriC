#include <CoreFoundation/CoreFoundation.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <stdio.h>

/* 只读探测 + 答案接收：注入 com.apple.siri。
   1) 记录 UILabel setText（只记录，不改）
   2) 从 notify a 槽读取 SpringBoard 送来的 AI 答案并打印（只打印，不改 UI） */

#define NB_SLOT 32

static int (*p_ntok_reg)(const char *, int *) = 0;
static int (*p_ntok_set)(int, unsigned long long) = 0;
static int (*p_ntok_post)(const char *) = 0;
static int (*p_ntok_get)(int, unsigned long long *) = 0;
static int g_ntok[NB_SLOT];
static int g_nfl = -1;
static unsigned long long g_nseq = 1;
static int g_nw_ready = 0;
static pthread_mutex_t g_wmu = PTHREAD_MUTEX_INITIALIZER;

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

static void log_line(const char *s) {
    char b[240];
    snprintf(b, sizeof b, "%s\n", s ? s : "");
    wtext(b);
}

static void chain_of(id v, char *out, int cap) {
    int n = 0;
    id cur = v;
    for (int i = 0; i < 8 && cur; i++) {
        const char *cn = class_getName(object_getClass(cur));
        n += snprintf(out + n, cap - n, "/%s", cn ? cn : "?");
        if (!((unsigned char(*)(id, SEL, SEL))objc_msgSend)(cur, sel_registerName("respondsToSelector:"),
                sel_registerName("superview"))) break;
        cur = ((id(*)(id, SEL))objc_msgSend)(cur, sel_registerName("superview"));
    }
    if (n >= cap) out[cap - 1] = 0;
}

static int g_hits = 0;

static void note_label(id lbl, const char *tag, id t) {
    if (!lbl || g_hits > 300) return;
    const char *u = 0;
    if (t && ((unsigned char(*)(id, SEL, SEL))objc_msgSend)(t, sel_registerName("respondsToSelector:"),
            sel_registerName("UTF8String")))
        u = ((const char*(*)(id, SEL))objc_msgSend)(t, sel_registerName("UTF8String"));
    g_hits++;
    char l[220];
    snprintf(l, sizeof l, "UITX %s len=%lu p=%p", tag, u ? (unsigned long)strlen(u) : 0UL, lbl);
    log_line(l);
    if (u && u[0]) {
        char pr[80];
        size_t k = strlen(u);
        if (k > 64) k = 64;
        pr[0] = '='; pr[1] = 0;
        memcpy(pr + 1, u, k);
        pr[1 + k] = 0;
        log_line(pr);
    }
    char ch[240];
    chain_of(lbl, ch, sizeof ch);
    snprintf(l, sizeof l, "UCH%s", ch);
    log_line(l);
}

static IMP o_setText = 0;
static IMP o_setAttr = 0;

static void my_setText(id self, SEL _cmd, id t) {
    note_label(self, "setText", t);
    if (o_setText) ((void(*)(id, SEL, id))o_setText)(self, _cmd, t);
}

static void my_setAttr(id self, SEL _cmd, id t) {
    note_label(self, "setAttr", t);
    if (o_setAttr) ((void(*)(id, SEL, id))o_setAttr)(self, _cmd, t);
}

static void install_hooks(void) {
    Class lc = objc_getClass("UILabel");
    if (lc) {
        Method m = class_getInstanceMethod(lc, sel_registerName("setText:"));
        if (m) o_setText = method_setImplementation(m, (IMP)my_setText);
        Method m2 = class_getInstanceMethod(lc, sel_registerName("setAttributedText:"));
        if (m2) o_setAttr = method_setImplementation(m2, (IMP)my_setAttr);
        log_line("UIPROBE hooks UILabel ok");
    } else {
        log_line("UIPROBE no UILabel");
    }
}

/* ---- 从 a 槽接收答案 ---- */
static int g_atok[NB_SLOT];
static int g_afl = -1;
static int g_aready = 0;
static unsigned long long g_last_seq = 0;

static long long cpval(int idx) {
    unsigned long long v = 0;
    if (idx < 0) return -1;
    if (p_ntok_get && p_ntok_get(idx, &v) == 0) return (long long)(v % 2097152ULL);
    return -1;
}

static void *ans_thread(void *a) {
    (void)a;
    sleep(3);
    p_ntok_get = dlsym(RTLD_DEFAULT, "notify_get_state");
    p_ntok_reg = dlsym(RTLD_DEFAULT, "notify_register_check");
    p_ntok_post = dlsym(RTLD_DEFAULT, "notify_post");
    p_ntok_set = dlsym(RTLD_DEFAULT, "notify_set_state");
    if (!p_ntok_reg || !p_ntok_get || !p_ntok_post) { log_line("UANS nodlsym"); return 0; }
    char nm[48];
    for (int i = 0; i < NB_SLOT; i++) {
        g_atok[i] = -1;
        snprintf(nm, sizeof nm, "com.doubao.a%d", i);
        p_ntok_reg(nm, &g_atok[i]);
    }
    p_ntok_reg("com.doubao.aflush", &g_afl);
    g_aready = 1;
    log_line("UANS listen");

    char buf[4200];
    int bn = 0;
    int idle = 0;
    for (;;) {
        usleep(150000);
        unsigned long long fl = 0;
        if (g_afl < 0 || p_ntok_get(g_afl, &fl) != 0) continue;
        if (fl == 0 || fl == g_last_seq) { idle++; continue; }
        if (fl > g_last_seq) {
            g_last_seq = fl;
            idle = 0;
            for (int i = 0; i < NB_SLOT; i++) {
                long long cp = cpval(g_atok[i]);
                if (cp <= 0) continue;
                if (cp < 0x80) buf[bn++] = (char)cp;
                else if (cp < 0x800) { buf[bn++] = 0xC0 | (cp >> 6); buf[bn++] = 0x80 | (cp & 0x3F); }
                else if (cp < 0x10000) { buf[bn++] = 0xE0 | (cp >> 12); buf[bn++] = 0x80 | ((cp >> 6) & 0x3F); buf[bn++] = 0x80 | (cp & 0x3F); }
                else { buf[bn++] = 0xF0 | (cp >> 18); buf[bn++] = 0x80 | ((cp >> 12) & 0x3F); buf[bn++] = 0x80 | ((cp >> 6) & 0x3F); buf[bn++] = 0x80 | (cp & 0x3F); }
                if (bn > 4000) break;
            }
            buf[bn] = 0;
        }
        if (idle >= 4 && bn > 0) {
            char l[80];
            snprintf(l, sizeof l, "UANS got len=%d", bn);
            log_line(l);
            log_line(buf);
            bn = 0;
        }
    }
    return 0;
}

static void *boot_thread(void *a) {
    (void)a;
    sleep(2);
    char b[160];
    snprintf(b, sizeof b, "UIPROBE BOOT pid=%d", getpid());
    log_line(b);
    install_hooks();
    return 0;
}

__attribute__((constructor)) static void ctor(void) {
    pthread_t th;
    if (pthread_create(&th, 0, boot_thread, 0) == 0) pthread_detach(th);
    if (pthread_create(&th, 0, ans_thread, 0) == 0) pthread_detach(th);
}
