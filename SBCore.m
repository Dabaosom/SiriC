#import "SiriBridge.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <dlfcn.h>

// ============ 日志（纯 C，禁止在启动期碰 NSString） ============
// SpringBoard 写不了普通文件；通道 = 32 槽 notify，com.doubao.nd2test 还原后写
// /var/mobile/Documents/aiassist/text.log（行首 "T "）。

#define NB_SLOT 32
#define SLOT_SHIFT 21

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
        usleep(400000);
    }
    pthread_mutex_unlock(&g_wmu);
}

// 异步队列：启动期只 strdup + pthread，绝不碰 ObjC
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

// ============ 运行时工具 ============

BOOL SBHasClass(NSString *name) { return objc_getClass(name.UTF8String) != Nil; }

BOOL SBHasSel(id obj, NSString *selName) {
    if (!obj || !selName.length) return NO;
    return [obj respondsToSelector:sel_registerName(selName.UTF8String)];
}

BOOL SBSet(id obj, NSString *selName, id value) {
    if (!obj || !value || !SBHasSel(obj, selName)) return NO;
    ((void (*)(id, SEL, id))objc_msgSend)(obj, sel_registerName(selName.UTF8String), value);
    return YES;
}

id SBNew(NSString *className) {
    Class c = objc_getClass(className.UTF8String);
    if (!c) return nil;
    id o = ((id (*)(id, SEL))objc_msgSend)((id)c, sel_registerName("alloc"));
    if (!o) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(o, sel_registerName("init"));
}

NSString *SBUUID(void) { return [[[NSUUID UUID] UUIDString] lowercaseString]; }

// ============ 主链路 ============

static BOOL g_busy = NO;
static int g_gen = 0;
static int g_probed = 0;

typedef struct { id conn; int gen; } SBJob;

#if SB_STAGE >= 2
static void SBOnAnswer(void *ctx, NSString *answer, NSString *err);

static void SBRequest(NSString *text, id conn) {
    if (g_busy) { SBLog("REQ busy drop"); return; }
    SBJob *job = calloc(1, sizeof(SBJob));
    if (!job) return;
    job->conn = [(id)conn retain];
    job->gen = ++g_gen;
    g_busy = YES;
    SBLog("REQ start gen=%d len=%lu", job->gen, (unsigned long)text.length);
    SBNetPost(text, SBOnAnswer, job);
}

static void SBOnAnswer(void *ctx, NSString *answer, NSString *err) {
    SBJob *job = (SBJob *)ctx;
    dispatch_async(dispatch_get_main_queue(), ^{
        g_busy = NO;
        if (job->gen != g_gen) SBLog("RES stale gen=%d now=%d", job->gen, g_gen);
        if (!answer.length) {
            SBLog("RES fail %s", err ? err.UTF8String : "?");
        } else {
            SBLog("RES answer len=%lu", (unsigned long)answer.length);
#if SB_STAGE >= 3
            id cmd = SBAceAddViews(answer);
            if (cmd) SBSubmitAce(cmd, job->conn);
#if SB_STAGE >= 4
            id tts = SBAcePreSynthTTS(answer);
            if (tts) SBSubmitAce(tts, job->conn);
#endif
#endif
        }
        [job->conn release];
        free(job);
    });
}
#endif

// 能力探测：只跑一次，且必须等 SpringBoard 完全起来后（首次识别回调）再跑
static void SBProbeOnce(void) {
    if (g_probed) return;
    g_probed = 1;

    const char *classes[] = { "AFConnection", "AFConnectionClientServiceDelegate",
                              "SAUIAddViews", "SAUIAssistantUtteranceView", "SAPreSynthesizeTTS" };
    for (int i = 0; i < 5; i++) {
        SBLog("PROBE class %s=%d", classes[i], objc_getClass(classes[i]) != Nil ? 1 : 0);
    }
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

static void SBOnText(NSString *text, id conn) {
    SBProbeOnce();
    SBLog("TEXT len=%lu", (unsigned long)text.length);
#if SB_STAGE >= 1
    if (!text.length) return;
    if (SBRouteNative(text)) return;
#if SB_STAGE >= 2
    SBRequest(text, conn);
#endif
#endif
}

// ============ 启动：只做注册，不碰 ObjC 对象、不打日志字符串 ============

__attribute__((constructor))
static void SBBoot(void) {
    sbStageMarker(0x5B01);              // 进入构造函数

    Class conn = objc_getClass("AFConnection");
    Class del = objc_getClass("AFConnectionClientServiceDelegate");
    sbStageMarker(0x5B11);              // 类查找完成

#if SB_STAGE >= 3
    BOOL subOk = SBSubmitInstall();
    sbStageMarker(subOk ? 0x5B21 : 0x5B22);
#endif
    BOOL recOk = SBInstallRecognitionHook(conn, del);
    sbStageMarker(recOk ? 0x5B31 : 0x5B32);
    SBSetTextFunc(SBOnText);
    sbStageMarker(0x5B41);              // 注册完成，构造函数结束
}
