#import "SiriBridge.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <time.h>
#include <string.h>
#include <dlfcn.h>

// ============ 日志 ============
// SpringBoard 沙箱写不了普通文件，正式通道走 32 槽 notify（notifd2 消费，写 text.log）。
// 同时尝试写容器文件，仅作旁路，失败不影响主通道。

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

// 异步队列：避免在 SpringBoard 主线程里跑 400ms 批间隔
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
    if (!s) return;
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

void SBLogLine(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (msg) {
        sbEnqueue(msg.UTF8String);
        [msg release];
    }
}

static void sbStageMarker(unsigned long long v) {
    int tok = -1;
    int (*reg)(const char *, int *) = (int (*)(const char *, int *))dlsym(RTLD_DEFAULT, "notify_register_check");
    int (*set)(int, unsigned long long) = (int (*)(int, unsigned long long))dlsym(RTLD_DEFAULT, "notify_set_state");
    int (*post)(const char *) = (int (*)(const char *))dlsym(RTLD_DEFAULT, "notify_post");
    if (!reg || !set || !post) return;
    if (reg("com.doubao.stage", &tok) != 0 || tok < 0) return;
    set(tok, v);
    post("com.doubao.stage");
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

typedef struct { id conn; int gen; } SBJob;

#if SB_STAGE >= 2
static void SBOnAnswer(void *ctx, NSString *answer, NSString *err);

static void SBRequest(NSString *text, id conn) {
    if (g_busy) { SBLog(@"REQ busy drop"); return; }
    SBJob *job = calloc(1, sizeof(SBJob));
    if (!job) return;
    job->conn = [(id)conn retain];
    job->gen = ++g_gen;
    g_busy = YES;
    SBLog(@"REQ start gen=%d len=%lu", job->gen, (unsigned long)text.length);
    SBNetPost(text, SBOnAnswer, job);
}

static void SBOnAnswer(void *ctx, NSString *answer, NSString *err) {
    SBJob *job = (SBJob *)ctx;
    dispatch_async(dispatch_get_main_queue(), ^{
        g_busy = NO;
        if (job->gen != g_gen) SBLog(@"RES stale gen=%d now=%d", job->gen, g_gen);
        if (!answer.length) {
            SBLog(@"RES fail %@", err ?: @"?");
        } else {
            SBLog(@"RES answer len=%lu", (unsigned long)answer.length);
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

static void SBOnText(NSString *text, id conn) {
    SBLog(@"TEXT len=%lu", (unsigned long)text.length);
#if SB_STAGE >= 1
    if (!text.length) return;
    if (SBRouteNative(text)) return;
#if SB_STAGE >= 2
    SBRequest(text, conn);
#endif
#endif
}

// ============ 能力探测 ============

static void SBProbe(void) {
    NSArray *classes = @[ @"AFConnection", @"AFConnectionClientServiceDelegate",
                          @"SAUIAddViews", @"SAUIAssistantUtteranceView", @"SAPreSynthesizeTTS" ];
    for (NSString *n in classes) SBLog(@"PROBE class %@=%d", n, (int)SBHasClass(n));

    Class conn = objc_getClass("AFConnection");
    if (conn) {
        NSArray *sels = @[ @"_tellSpeechDelegateSpeechRecognized:", @"_handleCommand:reply:",
                           @"startRequestWithText:", @"speechRecognized:" ];
        for (NSString *s in sels) {
            Method m = class_getInstanceMethod(conn, sel_registerName(s.UTF8String));
            SBLog(@"PROBE sel %@=%d", s, m ? 1 : 0);
        }
    }
}

// ============ 启动 ============

__attribute__((constructor))
static void SBBoot(void) {
    sbStageMarker(0x5B01);   // 构造已进入
    SBLog(@"BOOT stage=%d sb pid=%d", SB_STAGE,
          (int)[[NSProcessInfo processInfo] processIdentifier]);
    sbStageMarker(0x5B02);   // 日志入队完成
    SBProbe();
    sbStageMarker(0x5B03);   // 探针完成

    Class conn = objc_getClass("AFConnection");
    Class del = objc_getClass("AFConnectionClientServiceDelegate");
    if (!conn && !del) { SBLog(@"BOOT no AF classes"); return; }

#if SB_STAGE >= 3
    SBLog(@"BOOT submit=%d", (int)SBSubmitInstall());
#endif
    SBLog(@"BOOT recog=%d", (int)SBInstallRecognitionHook(conn, del));
    SBSetTextFunc(SBOnText);
}
