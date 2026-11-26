#import "SiriBridge.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <dlfcn.h>

// ============ 日志（纯 C） ============
// 通道：32 槽 notify，com.doubao.nd2test 还原后写 /var/mobile/Documents/aiassist/text.log

#define NB_SLOT 32

static int g_tok[NB_SLOT];
static int g_tokFlush = -1;
static unsigned long long g_seq = 1;
static int g_notifyReady = 0;
static int (*p_reg)(const char *, int *) = 0;
static int (*p_set)(int, unsigned long long) = 0;
static int (*p_post)(const char *) = 0;

static void sbNotifyInit(void) {
    if (g_notifyReady) return;
    p_reg = (int (*)(const char *, int *))dlsym(RTLD_DEFAULT, "notify_register_check");
    p_set = (int (*)(int, unsigned long long))dlsym(RTLD_DEFAULT, "notify_set_state");
    p_post = (int (*)(const char *))dlsym(RTLD_DEFAULT, "notify_post");
    if (!p_reg || !p_set || !p_post) return;
    char nm[48];
    for (int i = 0; i < NB_SLOT; i++) {
        g_tok[i] = -1;
        snprintf(nm, sizeof nm, "com.doubao.t%d", i);
        p_reg(nm, &g_tok[i]);
    }
    p_reg("com.doubao.tflush", &g_tokFlush);
    if (g_tokFlush >= 0) g_notifyReady = 1;
}

static void sbStageMarker(unsigned long long v) {
    int tok = -1;
    if (!p_reg) {
        p_reg = (int (*)(const char *, int *))dlsym(RTLD_DEFAULT, "notify_register_check");
        p_set = (int (*)(int, unsigned long long))dlsym(RTLD_DEFAULT, "notify_set_state");
        p_post = (int (*)(const char *))dlsym(RTLD_DEFAULT, "notify_post");
    }
    if (!p_reg || !p_set || !p_post) return;
    if (p_reg("com.doubao.stage", &tok) != 0 || tok < 0) return;
    p_set(tok, v);
    p_post("com.doubao.stage");
}

static pthread_mutex_t g_wmu = PTHREAD_MUTEX_INITIALIZER;

static void sbWriteText(const char *s) {
    sbNotifyInit();
    if (!g_notifyReady || !s) return;
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
            if (g_tok[i] < 0) continue;
            unsigned long cp = (i < nc) ? cps[i] : 0UL;
            p_set(g_tok[i], g_seq * 2097152ULL + (unsigned long long)cp);
        }
        p_set(g_tokFlush, g_seq);
        p_post("com.doubao.tflush");
        g_seq++;
        usleep(250000);
    }
    pthread_mutex_unlock(&g_wmu);
}

#define QN 96
static char *g_q[QN];
static int g_qh = 0, g_qt = 0;
static pthread_mutex_t g_qm = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_qc = PTHREAD_COND_INITIALIZER;
static int g_logStarted = 0;

static void *sbLogThread(void *a) {
    (void)a;
    for (;;) {
        pthread_mutex_lock(&g_qm);
        while (g_qh == g_qt) pthread_cond_wait(&g_qc, &g_qm);
        char *s = g_q[g_qh];
        g_q[g_qh] = NULL;
        g_qh = (g_qh + 1) % QN;
        pthread_mutex_unlock(&g_qm);
        sbWriteText(s);
        free(s);
    }
    return NULL;
}

static void sbEnqueue(const char *s) {
    if (!s || !*s) return;
    if (!g_logStarted) {
        g_logStarted = 1;
        pthread_t th;
        if (pthread_create(&th, NULL, sbLogThread, NULL) == 0) pthread_detach(th);
    }
    char *dup = strdup(s);
    if (!dup) return;
    pthread_mutex_lock(&g_qm);
    int next = (g_qt + 1) % QN;
    if (next == g_qh) { free(g_q[g_qh]); g_q[g_qh] = NULL; g_qh = (g_qh + 1) % QN; }
    g_q[g_qt] = dup;
    g_qt = next;
    pthread_cond_signal(&g_qc);
    pthread_mutex_unlock(&g_qm);
}

void SBLogF(const char *fmt, ...) {
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    sbEnqueue(buf);
}

// 同步日志：探针专用，写完才返回（崩溃不会丢这条）
void SBLogSync(const char *fmt, ...) {
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    sbWriteText(buf);
}

// ============ 运行时常量（禁止编译器字面量） ============

id SBMsgC(id obj, const char *sel) {
    if (!obj) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(obj, sel_registerName(sel));
}

id SBStr(const char *s) {
    static Class c;
    if (!c) c = objc_getClass("NSString");
    return ((id (*)(id, SEL, const char *))objc_msgSend)(
        (id)c, sel_registerName("stringWithUTF8String:"), s ? s : "");
}

id SBArr1(id o) {
    static Class c;
    if (!c) c = objc_getClass("NSArray");
    if (!o) return ((id (*)(id, SEL))objc_msgSend)((id)c, sel_registerName("array"));
    // 单参数，非变参：arrayWithObject:
    return ((id (*)(id, SEL, id))objc_msgSend)(
        (id)c, sel_registerName("arrayWithObject:"), o);
}

id SBDict2(id v1, id k1, id v2, id k2) {
    static Class c;
    if (!c) c = objc_getClass("NSMutableDictionary");
    id d = ((id (*)(id, SEL))objc_msgSend)((id)c, sel_registerName("dictionary"));
    if (!d) return nil;
    if (v1 && k1) ((void (*)(id, SEL, id, id))objc_msgSend)(
        d, sel_registerName("setObject:forKey:"), v1, k1);
    if (v2 && k2) ((void (*)(id, SEL, id, id))objc_msgSend)(
        d, sel_registerName("setObject:forKey:"), v2, k2);
    return d;
}

BOOL SBClassIs(id o, const char *clsName) {
    if (!o) return NO;
    Class c = object_getClass(o);
    const char *n = c ? class_getName(c) : NULL;
    if (!n) return NO;
    if (strcmp(n, clsName) == 0) return YES;
    // 子类也算（NSString/NSArray 常见簇）
    Class want = objc_getClass(clsName);
    while (c) {
        if (c == want) return YES;
        c = class_getSuperclass(c);
    }
    return NO;
}

BOOL SBHasClassC(const char *name) { return objc_getClass(name) != Nil; }

BOOL SBHasSelC(id obj, const char *sel) {
    if (!obj) return NO;
    return ((BOOL (*)(id, SEL, SEL))objc_msgSend)(
        obj, sel_registerName("respondsToSelector:"), sel_registerName(sel));
}

BOOL SBSetC(id obj, const char *sel, id value) {
    if (!obj || !value) return NO;
    if (!SBHasSelC(obj, sel)) return NO;
    ((void (*)(id, SEL, id))objc_msgSend)(obj, sel_registerName(sel), value);
    return YES;
}

id SBNewC(const char *clsName) {
    Class c = objc_getClass(clsName);
    if (!c) return nil;
    id o = ((id (*)(id, SEL))objc_msgSend)((id)c, sel_registerName("alloc"));
    if (!o) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(o, sel_registerName("init"));
}

id SBUUIDStr(void) {
    static Class c;
    if (!c) c = objc_getClass("NSUUID");
    id u = ((id (*)(id, SEL))objc_msgSend)((id)c, sel_registerName("UUID"));
    id s = SBMsgC(u, "UUIDString");
    return SBMsgC(s, "lowercaseString");
}

// ============ 主链路 ============

static void sbConstructProbe(void);

static BOOL g_busy = NO;
static int g_gen = 0;
static int g_probed = 0;

typedef struct { id conn; int gen; id answer; id err; } SBJob;

#if SB_STAGE >= 3
static void SBOnAnswer(void *ctx, id answer, id err);

static void SBRequest(id text, id conn) {
    if (g_busy) { SBLog("REQ busy drop"); return; }
    SBJob *job = calloc(1, sizeof(SBJob));
    if (!job) return;
    job->conn = SBMsgC(conn, "retain");
    job->gen = ++g_gen;
    g_busy = YES;
    SBLog("REQ start gen=%d", job->gen);
    SBNetPost(text, SBOnAnswer, job);
}

static void SBDoAnswer(void *ctx) {
    SBJob *job = (SBJob *)ctx;
    g_busy = NO;
    if (job->gen != g_gen) SBLog("RES stale gen=%d now=%d", job->gen, g_gen);
    const char *a = job->answer ? (const char *)SBMsgC(job->answer, "UTF8String") : NULL;
    if (!a || !*a) {
        const char *e = job->err ? (const char *)SBMsgC(job->err, "UTF8String") : "?";
        SBLog("RES fail %s", e);
    } else {
        SBLogSync("RES answer len=%lu", (unsigned long)strlen(a));
#if SB_STAGE >= 4
        id cmd = SBAceAddViews(job->answer);
        if (cmd) SBSubmitAce(cmd, job->conn);
#if SB_STAGE >= 5
        id tts = SBAcePreSynthTTS(job->answer);
        if (tts) SBSubmitAce(tts, job->conn);
#endif
#endif
    }
    SBMsgC(job->conn, "release");
    free(job);
}

static void SBOnAnswer(void *ctx, id answer, id err) {
    SBJob *job = (SBJob *)ctx;
    job->answer = answer ? SBMsgC(answer, "copy") : nil;
    if (err) job->err = SBMsgC(err, "copy");
    dispatch_async_f(dispatch_get_main_queue(), job, SBDoAnswer);
}
#endif

static void SBProbeOnce(void) {
    if (g_probed) return;
    g_probed = 1;
    const char *classes[] = { "AFConnection", "AFConnectionClientServiceDelegate",
                              "SAUIAddViews", "SAUIAssistantUtteranceView", "SAPreSynthesizeTTS" };
    for (int i = 0; i < 5; i++) SBLog("PROBE class %s=%d", classes[i], SBHasClassC(classes[i]) ? 1 : 0);
    Class conn = objc_getClass("AFConnection");
    if (conn) {
        const char *sels[] = { "_tellSpeechDelegateSpeechRecognized:", "_handleCommand:reply:",
                               "startRequestWithText:", "speechRecognized:" };
        for (int i = 0; i < 4; i++) {
            Method m = class_getInstanceMethod(conn, sel_registerName(sels[i]));
            SBLog("PROBE sel %s=%d", sels[i], m ? 1 : 0);
        }
    }
}

static void SBOnText(id text, id conn) {
#if SB_STAGE >= 2
    SBProbeOnce();
#endif
    const char *t = text ? (const char *)SBMsgC(text, "UTF8String") : NULL;
    SBLogSync("TEXT len=%lu", t ? (unsigned long)strlen(t) : 0UL);
#if SB_STAGE == 2
    static int probed = 0;
    if (!probed) { probed = 1; sbConstructProbe(); }
#endif
#if SB_STAGE >= 1
    if (!t || !*t) return;
    if (SBRouteNative(text)) return;
#if SB_STAGE >= 3
    SBRequest(text, conn);
#endif
#endif
}

// ============ 启动：只做注册 ============

// 探针只在「用户真的触发 Siri」时才跑（铁律14：启动阶段不跑危险测试）
// 每步一条同步日志，崩在哪条就是哪条不可用。
static void sbBlockProbe(void) {
    SBLogSync("SELFTEST blk ok");
}

static void sbConstructProbe(void) {
    SBLogSync("STEP 1 str");
    id s = SBStr("selftest-plain");
    SBLogSync("STEP 1 ok p=%p", (void *)s);

    SBLogSync("STEP 2 arr");
    id arr = SBArr1(s);
    SBLogSync("STEP 2 ok p=%p", (void *)arr);

    SBLogSync("STEP 3 dict");
    id dict = SBDict2(s, SBStr("k"), arr, SBStr("a"));
    SBLogSync("STEP 3 ok p=%p", (void *)dict);

    SBLogSync("STEP 4 uuid");
    id uuid = SBUUIDStr();
    SBLogSync("STEP 4 ok p=%p", (void *)uuid);

    SBLogSync("STEP 5 block");
    dispatch_async(dispatch_get_main_queue(), ^{ sbBlockProbe(); });
}

__attribute__((constructor))
static void SBBoot(void) {
    sbStageMarker(0x5B01);

    Class conn = objc_getClass("AFConnection");
    Class del = objc_getClass("AFConnectionClientServiceDelegate");
    sbStageMarker(0x5B11);

#if SB_STAGE >= 4
    BOOL subOk = SBSubmitInstall();
    sbStageMarker(subOk ? 0x5B21 : 0x5B22);
#endif
    BOOL recOk = SBInstallRecognitionHook(conn, del);
    sbStageMarker(recOk ? 0x5B31 : 0x5B32);
    SBSetTextFunc(SBOnText);
    sbStageMarker(0x5B41);

    SBLog("BOOT done");
}
