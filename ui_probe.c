#include <CoreFoundation/CoreFoundation.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <stdio.h>

/* 只读探测：注入 com.apple.siri，观察它的 UILabel 文本与父视图链。
   只记录，不修改任何文本。日志走既有的 notify 文本通道。 */

#define NB_SLOT 32

static int (*p_ntok_reg)(const char *, int *) = 0;
static int (*p_ntok_set)(int, unsigned long long) = 0;
static int (*p_ntok_post)(const char *) = 0;
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
    char b[220];
    snprintf(b, sizeof b, "%s\n", s ? s : "");
    wtext(b);
}

static const char *S(id o, const char *s) { return o ? sel_registerName(s) : s; }
static int resp(id o, const char *s) {
    if (!o) return 0;
    return ((unsigned char(*)(id, SEL, SEL))objc_msgSend)(o, sel_registerName("respondsToSelector:"),
            sel_registerName(s)) ? 1 : 0;
}

static int g_hits = 0;

static void chain_of(id v, char *out, int cap) {
    int n = 0;
    id cur = v;
    for (int i = 0; i < 8 && cur; i++) {
        const char *cn = class_getName(object_getClass(cur));
        n += snprintf(out + n, cap - n, "/%s", cn ? cn : "?");
        if (!resp(cur, "superview")) break;
        cur = ((id(*)(id, SEL))objc_msgSend)(cur, sel_registerName("superview"));
    }
    if (n >= cap) out[cap - 1] = 0;
}

static void note_label(id lbl, const char *tag, id t) {
    if (!lbl || g_hits > 300) return;
    const char *u = 0;
    if (t && resp(t, "UTF8String"))
        u = ((const char*(*)(id, SEL))objc_msgSend)(t, sel_registerName("UTF8String"));
    g_hits++;
    char l[200];
    snprintf(l, sizeof l, "UITX %s len=%lu p=%p", tag, u ? (unsigned long)strlen(u) : 0UL, lbl);
    log_line(l);
    if (u && u[0]) {
        char pr[60];
        size_t k = strlen(u);
        if (k > 52) k = 52;
        pr[0] = '='; pr[1] = 0;
        memcpy(pr + 1, u, k);
        pr[1 + k] = 0;
        log_line(pr);
    }
    char ch[220];
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
        if (m) { o_setText = method_setImplementation(m, (IMP)my_setText); }
        Method m2 = class_getInstanceMethod(lc, sel_registerName("setAttributedText:"));
        if (m2) { o_setAttr = method_setImplementation(m2, (IMP)my_setAttr); }
        log_line("UIPROBE hooks UILabel ok");
    } else {
        log_line("UIPROBE no UILabel");
    }
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
}
