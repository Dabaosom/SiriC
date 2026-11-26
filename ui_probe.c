#include <CoreFoundation/CoreFoundation.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <stdio.h>
#include <fcntl.h>

/* 注入 com.apple.siri。
   日志写自己的沙盒容器：$HOME/Library/Caches/uiprobe.log
   1) 记录 UILabel setText（只记录，不改）
   2) 从 notify a 槽接收 SpringBoard 的 AI 答案并记录（只记录，不改 UI） */

#define NB_SLOT 32

static int g_lfd = -1;
static pthread_mutex_t g_lmu = PTHREAD_MUTEX_INITIALIZER;

static void log_init(void) {
    if (g_lfd >= 0) return;
    const char *home = getenv("HOME");
    if (!home) return;
    char path[512];
    snprintf(path, sizeof path, "%s/Library/Caches/uiprobe.log", home);
    g_lfd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
}

static void log_line(const char *s) {
    log_init();
    if (g_lfd < 0 || !s) return;
    pthread_mutex_lock(&g_lmu);
    size_t n = strlen(s);
    char b[4400];
    if (n > 4200) n = 4200;
    memcpy(b, s, n);
    b[n] = '\n';
    write(g_lfd, b, n + 1);
    pthread_mutex_unlock(&g_lmu);
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
    if (!lbl || g_hits > 400) return;
    const char *u = 0;
    if (t && ((unsigned char(*)(id, SEL, SEL))objc_msgSend)(t, sel_registerName("respondsToSelector:"),
            sel_registerName("UTF8String")))
        u = ((const char*(*)(id, SEL))objc_msgSend)(t, sel_registerName("UTF8String"));
    g_hits++;
    char l[240];
    snprintf(l, sizeof l, "UITX %s len=%lu p=%p", tag, u ? (unsigned long)strlen(u) : 0UL, lbl);
    log_line(l);
    if (u && u[0]) {
        char pr[90];
        size_t k = strlen(u);
        if (k > 76) k = 76;
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
    if (!lc) { log_line("UIPROBE no UILabel"); return; }
    Method m = class_getInstanceMethod(lc, sel_registerName("setText:"));
    if (m) o_setText = method_setImplementation(m, (IMP)my_setText);
    Method m2 = class_getInstanceMethod(lc, sel_registerName("setAttributedText:"));
    if (m2) o_setAttr = method_setImplementation(m2, (IMP)my_setAttr);
    log_line("UIPROBE hooks UILabel ok");
}

/* ---- 从 a 槽接收答案 ---- */
static int (*nf_reg)(const char *, int *) = 0;
static int (*nf_get)(int, unsigned long long *) = 0;
static int g_atok[NB_SLOT];
static int g_afl = -1;
static unsigned long long g_last_seq = 0;

static long long cpval(int idx) {
    unsigned long long v = 0;
    if (idx < 0 || !nf_get) return -1;
    if (nf_get(idx, &v) == 0) return (long long)(v % 2097152ULL);
    return -1;
}

static void *ans_thread(void *a) {
    (void)a;
    sleep(3);
    nf_reg = dlsym(RTLD_DEFAULT, "notify_register_check");
    nf_get = dlsym(RTLD_DEFAULT, "notify_get_state");
    if (!nf_reg || !nf_get) { log_line("UANS nodlsym"); return 0; }
    char nm[48];
    for (int i = 0; i < NB_SLOT; i++) {
        g_atok[i] = -1;
        snprintf(nm, sizeof nm, "com.doubao.a%d", i);
        nf_reg(nm, &g_atok[i]);
    }
    nf_reg("com.doubao.aflush", &g_afl);
    {
        char l[120];
        snprintf(l, sizeof l, "UANS tok a0=%d fl=%d", g_atok[0], g_afl);
        log_line(l);
    }
    log_line("UANS listen");

    char buf[4200];
    int bn = 0;
    int idle = 0;
    int logged = 0;
    for (;;) {
        usleep(150000);
        unsigned long long fl = 0;
        if (g_afl < 0 || nf_get(g_afl, &fl) != 0) continue;
        if (fl != g_last_seq && logged < 40) {
            char l[100];
            snprintf(l, sizeof l, "UANS fl=%llu last=%llu", fl, g_last_seq);
            log_line(l);
            logged++;
        }
        if (fl == 0 || fl == g_last_seq) { idle++; continue; }
        if (fl > g_last_seq) {
            g_last_seq = fl;
            idle = 0;
            {
                long long c0 = cpval(g_atok[0]);
                long long c1 = cpval(g_atok[1]);
                char l[140];
                snprintf(l, sizeof l, "UANS dbg fl=%llu cp0=%lld cp1=%lld bn=%d", fl, c0, c1, bn);
                log_line(l);
            }
            for (int i = 0; i < NB_SLOT; i++) {
                long long cp = cpval(g_atok[i]);
                if (cp <= 0) continue;
                if (bn > 4000) break;
                if (cp < 0x80) buf[bn++] = (char)cp;
                else if (cp < 0x800) { buf[bn++] = (char)(0xC0 | (cp >> 6)); buf[bn++] = (char)(0x80 | (cp & 0x3F)); }
                else if (cp < 0x10000) { buf[bn++] = (char)(0xE0 | (cp >> 12)); buf[bn++] = (char)(0x80 | ((cp >> 6) & 0x3F)); buf[bn++] = (char)(0x80 | (cp & 0x3F)); }
                else { buf[bn++] = (char)(0xF0 | (cp >> 18)); buf[bn++] = (char)(0x80 | ((cp >> 12) & 0x3F)); buf[bn++] = (char)(0x80 | ((cp >> 6) & 0x3F)); buf[bn++] = (char)(0x80 | (cp & 0x3F)); }
            }
        }
        if (idle == 4) {
            char l2[90];
            snprintf(l2, sizeof l2, "UANS idle bn=%d", bn);
            log_line(l2);
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


/* ---- 网络自测：在 com.apple.siri 内用同步请求发一次 HTTPS（已验证可靠的路径） ---- */
static void net_test(void) {
    log_line("UNET begin");
    id req = ((id(*)(id, SEL))objc_msgSend)(
              ((id(*)(id, SEL))objc_msgSend)(objc_getClass("NSMutableURLRequest"), sel_registerName("alloc")),
              sel_registerName("init"));
    if (!req) { log_line("UNET no req"); return; }
    id url = ((id(*)(id, SEL, id))objc_msgSend)(objc_getClass("NSURL"),
              sel_registerName("URLWithString:"),
              ((id(*)(id, SEL, const char *))objc_msgSend)(objc_getClass("NSString"),
                  sel_registerName("stringWithUTF8String:"), "https://apihub.agnes-ai.com/v1/chat/completions"));
    ((void(*)(id, SEL, id))objc_msgSend)(req, sel_registerName("setURL:"), url);
    ((void(*)(id, SEL, id))objc_msgSend)(req, sel_registerName("setHTTPMethod:"),
        ((id(*)(id, SEL, const char *))objc_msgSend)(objc_getClass("NSString"),
            sel_registerName("stringWithUTF8String:"), "POST"));
    id ct = ((id(*)(id, SEL, const char *))objc_msgSend)(objc_getClass("NSString"),
        sel_registerName("stringWithUTF8String:"), "application/json");
    ((void(*)(id, SEL, id, id))objc_msgSend)(req, sel_registerName("setValue:forHTTPHeaderField:"),
        ct, ((id(*)(id, SEL, const char *))objc_msgSend)(objc_getClass("NSString"),
            sel_registerName("stringWithUTF8String:"), "Content-Type"));
    id auth = ((id(*)(id, SEL, const char *))objc_msgSend)(objc_getClass("NSString"),
        sel_registerName("stringWithUTF8String:"),
        "Bearer sk-V0QgHosRfr9EIMgHG6SdQX60z5zVq3JXG0zJ4uNfsPxdsmis");
    ((void(*)(id, SEL, id, id))objc_msgSend)(req, sel_registerName("setValue:forHTTPHeaderField:"),
        auth, ((id(*)(id, SEL, const char *))objc_msgSend)(objc_getClass("NSString"),
            sel_registerName("stringWithUTF8String:"), "Authorization"));
    id body = ((id(*)(id, SEL, const char *))objc_msgSend)(objc_getClass("NSString"),
        sel_registerName("stringWithUTF8String:"),
        "{\"model\":\"agnes-3.0-flash\",\"messages\":[{\"role\":\"user\",\"content\":\"讲个笑话\"}]}");
    id bdata = ((id(*)(id, SEL, unsigned long))objc_msgSend)(body,
        sel_registerName("dataUsingEncoding:"), 4UL);
    ((void(*)(id, SEL, id))objc_msgSend)(req, sel_registerName("setHTTPBody:"), bdata);

    id resp = 0, err = 0;
    id data = ((id(*)(id, SEL, id, id *, id *))objc_msgSend)(objc_getClass("NSURLConnection"),
        sel_registerName("sendSynchronousRequest:returningResponse:error:"), req, &resp, &err);
    char l[140];
    long dl = data ? (long)((unsigned long(*)(id, SEL))objc_msgSend)(data, sel_registerName("length")) : -1;
    long code = 0;
    if (resp) code = (long)((long(*)(id, SEL))objc_msgSend)(resp, sel_registerName("statusCode"));
    snprintf(l, sizeof l, "UNET done code=%ld len=%ld err=%d", code, dl, err ? 1 : 0);
    log_line(l);
    if (!data) return;
    id js = ((id(*)(id, SEL, id, unsigned long, id *))objc_msgSend)(objc_getClass("NSJSONSerialization"),
        sel_registerName("JSONObjectWithData:options:error:"), data, 0UL, (id *)0);
    id choices = js ? ((id(*)(id, SEL, id))objc_msgSend)(js, sel_registerName("objectForKey:"),
        ((id(*)(id, SEL, const char *))objc_msgSend)(objc_getClass("NSString"),
            sel_registerName("stringWithUTF8String:"), "choices")) : 0;
    id first = choices ? ((id(*)(id, SEL, unsigned long))objc_msgSend)(choices, sel_registerName("objectAtIndex:"), 0UL) : 0;
    id msg = first ? ((id(*)(id, SEL, id))objc_msgSend)(first, sel_registerName("objectForKey:"),
        ((id(*)(id, SEL, const char *))objc_msgSend)(objc_getClass("NSString"),
            sel_registerName("stringWithUTF8String:"), "message")) : 0;
    id content = msg ? ((id(*)(id, SEL, id))objc_msgSend)(msg, sel_registerName("objectForKey:"),
        ((id(*)(id, SEL, const char *))objc_msgSend)(objc_getClass("NSString"),
            sel_registerName("stringWithUTF8String:"), "content")) : 0;
    const char *u = content ? ((const char*(*)(id, SEL))objc_msgSend)(content, sel_registerName("UTF8String")) : 0;
    if (u) {
        char p2[130];
        size_t k = strlen(u);
        if (k > 110) k = 110;
        p2[0] = 'O'; p2[1] = '='; p2[2] = 0;
        memcpy(p2 + 2, u, k);
        p2[2 + k] = 0;
        log_line(p2);
    } else {
        log_line("UNET noparse");
    }
}

static void *boot_thread(void *a) {
    (void)a;
    sleep(1);
    log_init();
    char b[160];
    snprintf(b, sizeof b, "UIPROBE BOOT pid=%d", getpid());
    log_line(b);
    install_hooks();
    net_test();
    return 0;
}

__attribute__((constructor)) static void ctor(void) {
    pthread_t th;
    if (pthread_create(&th, 0, boot_thread, 0) == 0) pthread_detach(th);
    if (pthread_create(&th, 0, ans_thread, 0) == 0) pthread_detach(th);
}
