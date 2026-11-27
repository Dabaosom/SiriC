#define _XOPEN_SOURCE 700
#import "SiriBridge.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <dlfcn.h>
#include <signal.h>
#include <ucontext.h>
#include <sys/time.h>
#include <time.h>

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

// 调用方已持有 g_wmu 时的真实发送（每条 32 字符一批，每批 250ms）
static void sbWriteTextUnlocked(const char *s) {
    if (!s) return;
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
}

// 阻塞写：仅后台写线程与崩溃取证使用（会占住写锁若干百毫秒）
static void sbWriteText(const char *s) {
    sbNotifyInit();
    if (!g_notifyReady || !s) return;
    pthread_mutex_lock(&g_wmu);
    sbWriteTextUnlocked(s);
    pthread_mutex_unlock(&g_wmu);
}

#define QN 512
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

// 毫秒时间戳（相对首条日志），用于判读「识别 → 请求 → 响应 → 原生 AddViews → 窗口消失」的精确先后
static long long sbMs(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    long long now = (long long)tv.tv_sec * 1000LL + (long long)(tv.tv_usec / 1000);
    static long long t0 = 0;
    if (t0 == 0) t0 = now;
    return now - t0;
}

void SBLogF(const char *fmt, ...) {
    char body[512], buf[560];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(body, sizeof body, fmt, ap);
    va_end(ap);
    snprintf(buf, sizeof buf, "+%lldms %s", sbMs(), body);
    sbEnqueue(buf);
}

// 同步日志：1.4.8 起只入队、不发送 —— 任何调用线程（含主线程）都不再被 notify 通道阻塞。
void SBLogSync(const char *fmt, ...) {
    char body[512], buf[560];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(body, sizeof body, fmt, ap);
    va_end(ap);
    snprintf(buf, sizeof buf, "+%lldms %s", sbMs(), body);
    sbEnqueue(buf);
}

// 崩溃取证专用：真的写完才返回（会占住写锁）。只用在 SIG 处理与提交指令前一瞬间。
void SBLogCrit(const char *fmt, ...) {
    char body[512], buf[560];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(body, sizeof body, fmt, ap);
    va_end(ap);
    snprintf(buf, sizeof buf, "+%lldms %s", sbMs(), body);
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

// ============ 运行时空 block（reply 参数用） ============
// 不使用 block 字面量：isa/invoke 全部运行时落地。

typedef struct { unsigned long reserved; unsigned long size; void *copy; void *dispose; } SBBlkDesc;
typedef struct {
    void *isa;
    int flags;
    int reserved;
    void *invoke;
    SBBlkDesc *desc;
} SBBlk;

static SBBlk g_noopBlk;
static SBBlkDesc g_noopDesc;

static void sbNoopInvoke(void *blkSelf) {
    (void)blkSelf;
    SBLog("NOOP invoked");
}

// 用与 objc_msgSend 相同的方式给数据指针补 PAC 签名：
//   上下文 = 对象地址 | 0x6ae1<<48（obj 里 isa 的认证判别值，与 movk 一致）
static void *sbSignAsda(void *ptr, void *ctx) {
    void *p = ptr;
    __asm__ volatile(
        "mov x16, %[p]\n\t"
        "mov x10, %[c]\n\t"
        ".word 0xdac10950\n\t"          // pacda x16, x10（arm64 切片无 pauth 也能汇编）
        "mov %[p], x16\n\t"
        : [p] "+r"(p)
        : [c] "r"(ctx)
        : "x10", "x16", "memory");
    return p;
}

static void *sbSignAsia(void *ptr, void *ctx) {
    void *p = ptr;
    __asm__ volatile(
        "mov x16, %[p]\n\t"
        "mov x10, %[c]\n\t"
        ".word 0xdac10150\n\t"          // pacia x16, x10
        "mov %[p], x16\n\t"
        : [p] "+r"(p)
        : [c] "r"(ctx)
        : "x10", "x16", "memory");
    return p;
}

void *SBMakeNoopBlock(void) {
    // 真 clang block；RootHide 注入时 dyld 的认证重定位没执行，
    // 静态对象的 isa 是裸指针，这里替 dyld 把 isa 的签名补上。
    void (^blk)(void) = ^{
        SBLog("NOOP invoked");
    };
    void *rawIsa = *(void **)blk;
    SBBlk *copy = (SBBlk *)malloc(sizeof(SBBlk));
    if (!copy) return NULL;
    memcpy(copy, (const void *)blk, sizeof(SBBlk));
    void *ctx = (void *)((uintptr_t)copy | (0x6ae1ULL << 48));
    void *rawIsaClean = (void *)((uintptr_t)rawIsa & 0x000000ffffffffffULL);
    copy->isa = sbSignAsda(rawIsaClean, ctx);
    // invoke：A 密钥 + 字段地址（系统为 ldr x9,[x8,#0x10]! → blraa x9,x8）。
    // chained-fixup 条目的高位是编码位，必须先剥掉再签名（40 位掩码，
    // 同时兼容共享缓存类指针与本 dylib 地址）。
    void *rawInvoke = (void *)((uintptr_t)copy->invoke & 0x000000ffffffffffULL);
    copy->invoke = sbSignAsia(rawInvoke, (void *)&copy->invoke);
    SBLogSync("NOOP blk=%p rawisa=%p signed=%p", (void *)copy, rawIsa, copy->isa);
    SBLogSync("NOOP invoke raw=%p signed=%p", rawInvoke, copy->invoke);
    return (void *)copy;
}

// ============ 主链路 ============

static void sbConstructProbe(void);

static BOOL g_busy = NO;
BOOL SBAIPending(void) { return g_busy; }
void SBAISetPending(BOOL v) { g_busy = v; }
static int g_gen = 0;
static int g_probed = 0;

typedef struct { id conn; int gen; id answer; id err; id prompt; } SBJob;

// ============ 多轮上下文（1.6.5）============
// Siri 的对话上下文存在 assistantd 的服务端会话里，我们注入的 ACE 不在那里面，
// 所以历史只能自己留：保留最近 4 轮问答，超过 90 秒视为新会话（Siri 一轮交互很短，
// 隔久了接上一句会答非所问）。
#define SB_CTX_MAX 4
#define SB_CTX_GAP 90

static id g_cxUser[SB_CTX_MAX];
static id g_cxAns[SB_CTX_MAX];
static int g_cxN = 0;
static time_t g_cxLast = 0;

static void sbCtxClear(void) {
    for (int i = 0; i < g_cxN; i++) {
        if (g_cxUser[i]) { SBMsgC(g_cxUser[i], "release"); g_cxUser[i] = nil; }
        if (g_cxAns[i]) { SBMsgC(g_cxAns[i], "release"); g_cxAns[i] = nil; }
    }
    g_cxN = 0;
}

static void sbCtxAppend(id prompt, id answer) {
    if (!prompt || !answer) return;
    const char *a = (const char *)SBMsgC(answer, "UTF8String");
    if (!a || !*a) return;
    // 回答只留前 400 字节进历史，控制下一轮请求体量
    id keep = answer;
    NSUInteger len = [answer length];
    if (len > 400) keep = ((id (*)(id, SEL, unsigned long))objc_msgSend)(answer,
        sel_registerName("substringToIndex:"), 400UL);
    if (g_cxN >= SB_CTX_MAX) {
        if (g_cxUser[0]) SBMsgC(g_cxUser[0], "release");
        if (g_cxAns[0]) SBMsgC(g_cxAns[0], "release");
        for (int i = 1; i < SB_CTX_MAX; i++) { g_cxUser[i-1] = g_cxUser[i]; g_cxAns[i-1] = g_cxAns[i]; }
        g_cxN = SB_CTX_MAX - 1;
    }
    g_cxUser[g_cxN] = SBMsgC(prompt, "copy");
    g_cxAns[g_cxN] = SBMsgC(keep, "copy");
    g_cxN++;
    g_cxLast = time(NULL);
    SBLogSync("CTX append n=%d", g_cxN);
}

id SBMessagesFor(id prompt) {
    if (!prompt) return nil;
    time_t now = time(NULL);
    if (g_cxN > 0 && now - g_cxLast > SB_CTX_GAP) {
        SBLogSync("CTX clear gap=%ld", (long)(now - g_cxLast));
        sbCtxClear();
    }
    id arr = ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("NSMutableArray"),
                                             sel_registerName("array"));
    if (!arr) return nil;

    // 1.6.6：系统提示。① 回答要口语、简短；② 需要动设备时只输出一行 JSON，
    // 由插件去执行（不经过原生），并且把设备上真实存在的快捷指令名喂给它，避免瞎编。
    {
        id sysPrompt = SBStr(
            "你是iPhone上的中文语音助手。回答用简体口语，控制在150字以内。"
            "如果用户要你执行设备操作，只输出一行JSON、不要任何解释："
            "{\"action\":\"shortcut\",\"name\":\"快捷指令名\"}。"
            "可用的快捷指令名如下（只能从中选，名字要一字不差）：");
        id names = SBShortcutNamesCSV();
        id full = nil;
        if (names) {
            full = ((id (*)(id, SEL, id))objc_msgSend)(sysPrompt, sel_registerName("stringByAppendingString:"), names);
        }
        id sd = SBDict2(full ? full : sysPrompt, SBStr("content"), SBStr("system"), SBStr("role"));
        if (sd) ((void (*)(id, SEL, id, unsigned long))objc_msgSend)(arr, sel_registerName("insertObject:atIndex:"), sd, 0UL);
    }

    for (int i = 0; i < g_cxN; i++) {
        id m1 = SBDict2(g_cxUser[i], SBStr("content"), SBStr("user"), SBStr("role"));
        id m2 = SBDict2(g_cxAns[i], SBStr("content"), SBStr("assistant"), SBStr("role"));
        if (m1) ((void (*)(id, SEL, id))objc_msgSend)(arr, sel_registerName("addObject:"), m1);
        if (m2) ((void (*)(id, SEL, id))objc_msgSend)(arr, sel_registerName("addObject:"), m2);
    }
    id mc = SBDict2(prompt, SBStr("content"), SBStr("user"), SBStr("role"));
    if (mc) ((void (*)(id, SEL, id))objc_msgSend)(arr, sel_registerName("addObject:"), mc);
    SBLogSync("CTX build turns=%d", g_cxN);
    return arr;
}


#if SB_STAGE >= 3
static void SBOnAnswer(void *ctx, id answer, id err);
static void SBDoAnswer(void *ctx);

// 从 JSON 里取 "key":"value"（不建 ObjC 字典，纯字节扫描，够用就行）
static const char *sbJsonStr(const char *json, const char *key, int keylen, char *buf, int sz) {
    const char *p = json;
    while ((p = strstr(p, key))) {
        const char *q = p + keylen;
        while (*q == ' ' || *q == '\t' || *q == '\n') q++;
        if (*q != ':') { p = q; continue; }
        q++;
        while (*q == ' ' || *q == '\t' || *q == '\n') q++;
        if (*q != '"') { p = q; continue; }
        q++;
        int n = 0;
        while (*q && *q != '"' && n < sz - 1) {
            if (*q == '\\' && q[1]) q++;
            buf[n++] = *q++;
        }
        buf[n] = 0;
        return buf;
    }
    return NULL;
}

// 1.6.6：识别并执行 AI 下发的动作。目前只接快捷指令（第三层先做一个闭环）。
static int sbTryAct(const char *a, id conn) {
    if (!a) return 0;
    const char *brace = strchr(a, '{');
    if (!brace) return 0;
    char act[32];
    if (!sbJsonStr(brace, "\"action\"", 8, act, sizeof act)) return 0;
    SBLogSync("ACT detect %s", act);
    if (!strcmp(act, "shortcut")) {
        char name[160];
        if (!sbJsonStr(brace, "\"name\"", 6, name, sizeof name) || !name[0]) {
            SBLogSync("ACT shortcut noname");
            return 0;
        }
        SBLogSync("ACT run shortcut %s", name);
        return SBShortcutRunNamed(name, conn) ? 1 : 0;
    }
    // app / url 留给下一步；先记下来，避免静默变成念一段 JSON
    SBLogSync("ACT unsupported %s", act);
    return 0;
}

static void SBRequest(id text, id conn) {
    if (g_busy) { SBLog("REQ busy drop"); return; }
    SBJob *job = calloc(1, sizeof(SBJob));
    if (!job) return;
    const char *cc = conn ? class_getName(object_getClass(conn)) : "(nil)";
    SBLogSync("REQ conn=%p cls=%s", (void *)conn, cc);
    job->conn = SBMsgC(conn, "retain");
    job->prompt = SBMsgC(text, "copy");
    job->gen = ++g_gen;
    g_busy = YES;

#if SB_SYNC_AI
    // 1.4.5：在识别链里同步等答案（与 SiriPlus 时序一致），拿到后回主队列异步提交。
    SBLogSync("SYNC begin main=%d", pthread_main_np() ? 1 : 0);
    id err = nil;
    job->answer = SBNetPostSync(text, 3.0, &err);
    job->err = err;
    const char *sy = job->answer ? (const char *)SBMsgC(job->answer, "UTF8String") : NULL;
    SBLogSync("SYNC end len=%lu", sy ? (unsigned long)strlen(sy) : 0UL);
    g_busy = NO;
    SBLogSync("SYNC main submit");
    dispatch_async_f(dispatch_get_main_queue(), job, SBDoAnswer);
    return;
#endif

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
        // 1.5.5 兜底：AI 失败时把存下的原生回执放行，让 Siri 自己收尾，避免窗口永远在途。
        SBFlushHeldReply();
    } else {
        SBLogSync("RES answer len=%lu", (unsigned long)strlen(a));
        // 1.6.6：先看是不是结构化动作指令（模型按系统提示只会输出一行 JSON）。
        int acted = sbTryAct(a, job->conn);
        // 1.6.5：只有真的出了答案才记入上下文（失败轮不进历史，避免污染下一轮）。
        if (!acted && job->gen == g_gen) sbCtxAppend(job->prompt, job->answer);
#if SB_STAGE >= 4 && SB_NET_SUBMIT
        if (!acted) {
            id cmd = SBAceAddViews(job->answer);
            if (cmd) SBSubmitAce(cmd, job->conn);
#if SB_STAGE >= 5
            id tts = SBAcePreSynthTTS(job->answer);
            if (tts) SBSubmitAce(tts, job->conn);
#endif
        }
#endif
    }
    SBMsgC(job->conn, "release");
    if (job->prompt) SBMsgC(job->prompt, "release");
    free(job);
}

static void SBOnAnswer(void *ctx, id answer, id err) {
    SBJob *job = (SBJob *)ctx;
    job->answer = answer ? SBMsgC(answer, "copy") : nil;
    if (err) job->err = SBMsgC(err, "copy");
#if SB_STAGE >= 4
    // 与 SiriPlus 一致：AI 文本落地后 DispatchQueue.main.async 提交 ACE。
    // isa 签名问题解决后，提交不再依赖调用线程。
    SBLogSync("RES main submit");
    dispatch_async_f(dispatch_get_main_queue(), job, SBDoAnswer);
#else
    dispatch_async_f(dispatch_get_main_queue(), job, SBDoAnswer);
#endif
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
    SBLog("TEXT len=%lu", t ? (unsigned long)strlen(t) : 0UL);
    if (t) SBLogSync("TEXT q=<%s>", t);
#if SB_STAGE == 2
    static int probed = 0;
    if (!probed) { probed = 1; sbConstructProbe(); }
#endif
#if SB_STAGE >= 1
    if (!t || !*t) return;
    if (SBShortcutTry(text, conn)) return;
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

// arm64e SDK 的 thread_state 字段是 opaque 名，这里按固定布局自读寄存器
typedef struct { unsigned long long x[29]; unsigned long long fp, lr, sp, pc; } SbTS;
typedef struct { unsigned long long far_; unsigned int esr_; unsigned int exc_; SbTS ss; } SbMC;

static void sbSigHandler(int sig, siginfo_t *si, void *uc) {
    static volatile int g_inSig = 0;
    if (g_inSig) { signal(sig, SIG_DFL); return; }
    g_inSig = 1;
    ucontext_t *u = (ucontext_t *)uc;
    if (u && u->uc_mcontext) {
        const SbMC *m = (const SbMC *)u->uc_mcontext;
        SBLogCrit("SIG%d far=%p pc=%p lr=%p", sig, si ? si->si_addr : NULL,
                  (void *)m->ss.pc, (void *)m->ss.lr);
        SBLogCrit("SIG%d x0=%p x1=%p x2=%p", sig,
                  (void *)m->ss.x[0], (void *)m->ss.x[1], (void *)m->ss.x[2]);
        SBLogCrit("SIG%d x3=%p x8=%p sp=%p", sig,
                  (void *)m->ss.x[3], (void *)m->ss.x[8], (void *)m->ss.sp);
        SBLogCrit("SIG%d x16=%p x17=%p x9=%p", sig,
                  (void *)m->ss.x[16], (void *)m->ss.x[17], (void *)m->ss.x[9]);
        SBLogCrit("SIG%d x10=%p x11=%p x12=%p", sig,
                  (void *)m->ss.x[10], (void *)m->ss.x[11], (void *)m->ss.x[12]);
        SBLogCrit("SIG%d x13=%p x14=%p x15=%p", sig,
                  (void *)m->ss.x[13], (void *)m->ss.x[14], (void *)m->ss.x[15]);
        // 读出崩溃点前后各 4 条指令，本地反汇编定位语义
        unsigned long long ppc = m->ss.pc & 0x00007fffffffffffULL;
        if (ppc > 0x100000000ULL && ppc < 0x300000000ULL) {
            const volatile unsigned int *base = (const volatile unsigned int *)(uintptr_t)(ppc - 16);
            for (int i = 0; i < 8; i += 2) {
                SBLogCrit("SIG%d iw%d %08x %08x", sig, i, base[i], base[i + 1]);
            }
        }
        // 调用方窗口：lr-4 即系统调用 reply 的那条指令，决定密钥与上下文
        unsigned long long plr = m->ss.lr & 0x00007fffffffffffULL;
        if (plr > 0x100000000ULL && plr < 0x300000000ULL) {
            const volatile unsigned int *lb = (const volatile unsigned int *)(uintptr_t)(plr - 20);
            for (int i = 0; i < 8; i += 2) {
                SBLogCrit("SIG%d lw%d %08x %08x", sig, i, lb[i], lb[i + 1]);
            }
        }
        // SEL 本质就是字符串指针：把 x1 当方法名读出来（限定 shared cache 范围）
        unsigned long long sp1 = m->ss.x[1];
        if (sp1 > 0x100000000ULL && sp1 < 0x300000000ULL) {
            char nm[33];
            int k = 0;
            const unsigned char *p = (const unsigned char *)(uintptr_t)sp1;
            for (; k < 32; k++) {
                unsigned char ch = p[k];
                if (ch < 0x20 || ch > 0x7e) break;
                nm[k] = (char)ch;
            }
            nm[k] = 0;
            if (k > 1) SBLogCrit("SIG%d sel=%s", sig, nm);
        }
    } else {
        SBLogCrit("SIG%d nocontext far=%p", sig, si ? si->si_addr : NULL);
    }
    signal(sig, SIG_DFL);
}

void SBSignalGuard(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = sbSigHandler;
    sa.sa_flags = SA_SIGINFO;
    sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGILL, &sa, NULL);
    sigaction(SIGTRAP, &sa, NULL);
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

    SBSignalGuard();
    SBObserveInstall();
    SBLog("BOOT done");
    // 1.6.3：启动期的 204 条方法表 dump 是纯调试，每次 SpringBoard 启动要占 1~2 分钟
    // 日志锁与写盘（对耗电、启动速度都无意义）。改为编译期开关，默认关闭。
#if SB_SELFTEST
    SBSelfTestDump("boot");
#endif

    // 快捷指令名单预热：放到后台线程，启动期不阻塞（内部分失败会自己打日志）。
    pthread_t scth;
    if (pthread_create(&scth, NULL, SBShortcutLoadThreadMain, NULL) == 0) pthread_detach(scth);
    else SBLogSync("SC preload thread fail");
}
