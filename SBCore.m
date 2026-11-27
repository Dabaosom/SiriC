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
#include <sys/stat.h>
#include <errno.h>
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

// 1.6.37：notify 通道依赖 notifd，整机重启后它就不写文件了，日志全盲。
// 所以加一条完全独立的文件通道：直接 fopen 追加，不走 notify。
// SpringBoard 在 RootHide 的 jbroot 视图里，写 /var/mobile/Documents/aiassist/text.log
// 会落到 jbroot 那份（root 侧从 .jbroot-*/var/mobile/Documents/aiassist/text.log 读）。
static int g_lfInit = 0;
static FILE *g_lfArr[6] = {0};

static void sbFileOpen(void) {
    if (g_lfInit) return;
    g_lfInit = 1;
    char homePath[420];
    const char *hp = getenv("HOME");
    const char *cand[6];
    int nc = 0;
    cand[nc++] = SB_HOME_DIR "/sb.log";          // 1.6.39：sb.conf 同目录，已验证可读写
    cand[nc++] = "/var/mobile/Documents/aiassist/text.log";
    if (hp && *hp) {
        snprintf(homePath, sizeof homePath, "%s/Documents/sb.log", hp);
        cand[nc++] = strdup(homePath);
    }
    if (hp && *hp) {
        snprintf(homePath, sizeof homePath, "%s/Library/Caches/sb.log", hp);
        cand[nc++] = strdup(homePath);
    }
    cand[nc++] = "/var/mobile/Containers/Data/Application/E2865C3B-E526-43CF-AAC0-2AD87C0C18AC/Documents/sb_sb.log";
    cand[nc++] = NULL;
    for (int i = 0; i < nc; i++) {
        g_lfArr[i] = fopen(cand[i], "a");
    }
}

static void sbFileWrite(const char *s) {
    if (!s) return;
    sbFileOpen();
    for (int i = 0; i < 6; i++) {
        if (!g_lfArr[i]) continue;
        fprintf(g_lfArr[i], "%s\n", s);
        fflush(g_lfArr[i]);
    }
}

// 阻塞写：仅后台写线程与崩溃取证使用（会占住写锁若干百毫秒）
static void sbWriteText(const char *s) {
    if (!s) return;
    sbNotifyInit();
    pthread_mutex_lock(&g_wmu);
    sbFileWrite(s);                          // 文件通道，与 notify 无关
    if (g_notifyReady) sbWriteTextUnlocked(s);
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
// 1.6.18：g_busy 是「我们这一轮在途」（吞原生指令、按住关窗都看它），
// 而 g_reqBusy 只负责「AI 请求是否还没回来」的并发互斥 —— 两者混用会让
// 一条卡住的快捷指令把后续所有语音请求都按 REQ busy drop 丢掉。
static BOOL g_reqBusy = NO;
static time_t g_pendAt = 0;
// 1.6.19：答案一提交 g_busy 就清了，但此时还在念。打断必须看「本轮是否还在屏幕上」，
// 这个标志由提交处置 YES、viewWillDisappear 置 NO。
static BOOL g_onScreen = NO;
void SBTurnOnScreen(BOOL v) { g_onScreen = v; }
BOOL SBAIPending(void) { return g_busy; }
void SBAISetPending(BOOL v) { g_busy = v; g_pendAt = v ? time(NULL) : 0; }
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
    // 1.6.23：回答留前 800 字节进历史，且尽量切在句末，别把一句话砍成半句
    id keep = answer;
    NSUInteger len = [answer length];
    if (len > 800) {
        id cut = ((id (*)(id, SEL, unsigned long))objc_msgSend)(answer,
            sel_registerName("substringToIndex:"), 800UL);
        if (cut) {
            // 从尾部往前找最近的句末标点（中文 3 字节，用字符串查找即可）
            const char *cs = (const char *)SBMsgC(cut, "UTF8String");
            if (cs) {
                size_t cutLen = 0;
                for (size_t i = strlen(cs); i > 0; i--) {
                    if (!strncmp(cs + i - 3, "。", 3) || !strncmp(cs + i - 3, "！", 3) ||
                        !strncmp(cs + i - 3, "？", 3)) { cutLen = i; break; }
                }
                if (cutLen > 200) {
                    id t2 = NULL;
                    char *tmp = strndup(cs, cutLen);
                    if (tmp) { t2 = SBStr(tmp); free(tmp); }
                    if (t2) cut = t2;
                }
            }
        }
        if (cut) keep = cut;
    }
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

// ============ 长期记忆（1.6.23）============
// 1.6.25：改放 /var/mobile/Library/SiriBridge/。原来放 Documents 下，SpringBoard 里 fopen 失败
// （RootHide 的视图隔离 + 沙盒），日志里一直是 MEM none / CONF none。Library 是 SpringBoard 自己的目录，稳定可读写。
#define SB_MEM_PATH SB_HOME_DIR "/memory.txt"
#define SB_MEM_OLD  "/var/mobile/Documents/aiassist/memory.txt"
#define SB_MEM_MAX 8
#define SB_MEM_LEN 160

static char g_mem[SB_MEM_MAX][SB_MEM_LEN];
static int g_memN = -1;

static void sbMemLoad(void) {
    if (g_memN >= 0) return;
    g_memN = 0;
    FILE *f = fopen(SB_MEM_PATH, "r");
    if (!f) f = fopen(SB_MEM_OLD, "r");   // 兼容旧路径
    if (!f) { SBLogSync("MEM none errno=%d", errno); return; }
    char line[SB_MEM_LEN + 8];
    while (fgets(line, sizeof line, f) && g_memN < SB_MEM_MAX) {
        size_t n = strlen(line);
        while (n && (line[n-1] == '\n' || line[n-1] == '\r')) line[--n] = 0;
        if (!n) continue;
        strncpy(g_mem[g_memN], line, SB_MEM_LEN - 1);
        g_mem[g_memN][SB_MEM_LEN - 1] = 0;
        g_memN++;
    }
    fclose(f);
    SBLogSync("MEM load n=%d", g_memN);
}

static void sbMemAdd(const char *text) {
    if (!text || !*text) return;
    sbMemLoad();
    mkdir(SB_HOME_DIR, 0777);
    FILE *f = fopen(SB_MEM_PATH, "a");
    if (f) { fprintf(f, "%s\n", text); fclose(f); }
    else SBLogSync("MEM write fail errno=%d", errno);
    if (g_memN < SB_MEM_MAX) {
        strncpy(g_mem[g_memN], text, SB_MEM_LEN - 1);
        g_mem[g_memN][SB_MEM_LEN - 1] = 0;
        g_memN++;
    } else {
        for (int i = 1; i < SB_MEM_MAX; i++) memcpy(g_mem[i-1], g_mem[i], SB_MEM_LEN);
        strncpy(g_mem[SB_MEM_MAX-1], text, SB_MEM_LEN - 1);
    }
    SBLogSync("MEM add <%s>", text);
}

static id sbMemText(void) {
    sbMemLoad();
    if (g_memN <= 0) return nil;
    char buf[1400];
    size_t used = 0;
    buf[0] = 0;
    for (int i = 0; i < g_memN; i++) {
        size_t n = strlen(g_mem[i]);
        if (used + n + 2 >= sizeof buf) break;
        if (used) buf[used++] = ';';   // 用分号分隔，避免和模型的分句冲突
        memcpy(buf + used, g_mem[i], n);
        used += n;
    }
    buf[used] = 0;
    return SBStr(buf);
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
        // 1.6.17：从“播报资料”改成“对话”。先一句直答，再最多补一句要点；
        // 不说话术废话、不复述问题、不用列表和 markdown（Siri 念不出来）。
        id sysPrompt = SBStr(
            "你是iPhone上的中文语音助手，说话像一个反应快的朋友，不是播报机器。"
            "规则：①先直接回答，第一句就是答案本身，不超过30字；"
            "②确实需要补充时最多再补一句，总共不超过80字；"
            "③不复述问题、不说“好的”“让我想想”之类的话术；"
            "④不用列表、编号、markdown、括号注释；数字用中文读法，英文缩写能换成中文就换；"
            "⑤不确定就直说不知道，不要编。"
            "如果用户要你执行设备操作，只输出一行JSON、不要任何解释，四选一："
            "{\"action\":\"shortcut\",\"name\":\"快捷指令名\"} / "
            "{\"action\":\"app\",\"name\":\"App名字\"} / "
            "{\"action\":\"url\",\"value\":\"https://...\"} / "
            "{\"action\":\"remember\",\"text\":\"要记住的事实\"}（用户明确要你记住时用）。"
            "可用的快捷指令名如下（只能从中选，名字要一字不差）：");
        id names = SBShortcutNamesCSV();
        id full = nil;
        if (names) {
            full = ((id (*)(id, SEL, id))objc_msgSend)(sysPrompt, sel_registerName("stringByAppendingString:"), names);
        }
        // 1.6.23：长期记忆里的用户事实也拼进系统提示
        id mem = sbMemText();
        id base = full ? full : sysPrompt;
        if (mem) {
            id pre = SBStr("。已知用户信息（可直接当真）：");
            id m1 = ((id (*)(id, SEL, id))objc_msgSend)(base, sel_registerName("stringByAppendingString:"), pre);
            if (m1) {
                id m2 = ((id (*)(id, SEL, id))objc_msgSend)(m1, sel_registerName("stringByAppendingString:"), mem);
                if (m2) { base = m2; SBLogSync("MEM inject n=%d", g_memN); }
            }
        }
        id sd = SBDict2(base, SBStr("content"), SBStr("system"), SBStr("role"));
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

// 1.6.7：动作类回答统一用一句自造文本收尾（不念模型给的 JSON）。
typedef struct { id conn; char *text; } SBSayJob;

static void sbSayRun(void *p) {
    SBSayJob *j = (SBSayJob *)p;
    SBLogSync("SAY %s", j->text);
    id t = SBStr(j->text);
    if (t) {
        id cmd = SBAceAddViews(t);
        if (cmd) SBSubmitAce(cmd, j->conn);
        else SBFlushHeldReply();   // 1.6.9：ACE 没造出来时兜底结账，别把窗口挂到 12 秒超时
    }
    SBMsgC(j->conn, "release");
    free(j->text);
    free(j);
}

// 1.6.10 流式首句：只提交 TTS，不提交 AddViews。
// 关键：TTS 提交不结账（SBSubmit 只在非 TTS 时 flush held reply），
// 所以窗口还留着；等整段答案到了再出 UI 并只念剩下的部分。
typedef struct { id conn; char *text; } SBPartJob;
static id g_partRef = NULL;   // 1.6.14：首句那条的 refId，收尾复用，争取原地合并成一条气泡

static void sbPartRun(void *p) {
    SBPartJob *j = (SBPartJob *)p;
    SBLogSync("PART submit len=%lu +%llums", (unsigned long)strlen(j->text), SBNetElapsedMs());
    id t = SBStr(j->text);
    if (t) {
        // 1.6.13：实测 AddViews 会念 speakableText，所以首句只发一条不结账的 AddViews 即可，
        // 不再需要 TTS（之前纯 TTS 无声、AddViews+TTS 又重复，都是这条性质造成的）。
        // 1.6.16：回退 1.6.15 的 Acknowledgment（实测那一档会把收尾的全文吃掉，只剩首句）。
        //         仍用 Completion，就是 1.6.14 的表现：两条气泡、声音正确。
        id cmd = SBAceAddViewsPhase(t, t, nil, "Completion");
        if (cmd) {
            id ref = ((id (*)(id, SEL))objc_msgSend)(cmd, sel_registerName("refId"));
            if (ref) {
                if (g_partRef) SBMsgC(g_partRef, "release");
                g_partRef = SBMsgC(ref, "copy");
            }
            SBSubmitAceNoFlush(cmd, j->conn);
        }
    }
    SBMsgC(j->conn, "release");
    free(j->text);
    free(j);
}

void SBNetPartial(const char *text, void *ctx) {
    SBJob *job = (SBJob *)ctx;
    if (!text || !*text || !job || !job->conn) return;
    SBPartJob *j = calloc(1, sizeof(SBPartJob));
    if (!j) return;
    j->conn = SBMsgC(job->conn, "retain");
    j->text = strdup(text);
    dispatch_async_f(dispatch_get_main_queue(), j, sbPartRun);
}

void SBSayAsync(const char *text, id conn) {
    if (!text || !*text || !conn) return;
    SBSayJob *j = calloc(1, sizeof(SBSayJob));
    if (!j) return;
    j->conn = SBMsgC(conn, "retain");
    j->text = strdup(text);
    dispatch_async_f(dispatch_get_main_queue(), j, sbSayRun);
}

// 1.6.8：打开 App / 打开链接一律丢到后台线程做。
// 实测在主线程调 openURL 时带了中文未编码地址，直接把 SpringBoard 卡死（日志停在 URL open 之前）。
typedef struct { id conn; char *arg; int isUrl; } SBActJob;

static void *sbActThread(void *p) {
    SBActJob *j = (SBActJob *)p;
    BOOL ok = j->isUrl ? SBOpenURLString(j->arg) : SBOpenAppNamed(j->arg);
    char *msg = calloc(1, 256);
    if (msg) {
        if (j->isUrl) snprintf(msg, 256, ok ? "已经打开了" : "这个链接打不开");
        else snprintf(msg, 256, ok ? "已打开%s" : "没找到%s这个 App", j->arg);
        SBSayAsync(msg, j->conn);
        free(msg);
    }
    SBMsgC(j->conn, "release");
    free(j->arg);
    free(j);
    return NULL;
}

static int sbActDispatch(const char *arg, int isUrl, id conn) {
    SBActJob *j = calloc(1, sizeof(SBActJob));
    if (!j) return 0;
    j->conn = SBMsgC(conn, "retain");
    j->arg = strdup(arg);
    j->isUrl = isUrl;
    pthread_t th;
    if (pthread_create(&th, NULL, sbActThread, j) != 0) {
        SBMsgC(j->conn, "release");
        free(j->arg);
        free(j);
        return 0;
    }
    pthread_detach(th);
    return 1;
}

static void SBRequest(id text, id conn);   // 1.6.23：剪贴板分支要再起一轮请求
static id sbClipReadCached(void);          // 1.6.24：剪贴板统一走带缓存的读取

// 1.6.23：读剪贴板文字（clip 动作的兜底路径，正常不会走到——1.6.24 已在识别阶段预判）
static id sbClipText(void) { return sbClipReadCached(); }

// 1.6.6：识别并执行 AI 下发的动作。action 支持 shortcut / app / url / clip / remember。
static int sbTryAct(const char *a, id conn, SBJob *job) {
    if (!a) return 0;
    const char *brace = strchr(a, '{');
    if (!brace) return 0;
    char act[32];
    if (!sbJsonStr(brace, "\"action\"", 8, act, sizeof act)) return 0;
    SBLogSync("ACT detect %s", act);
    char val[512];

    if (!strcmp(act, "shortcut")) {
        if (!sbJsonStr(brace, "\"name\"", 6, val, sizeof val) || !val[0]) {
            SBLogSync("ACT shortcut noname");
            return 0;
        }
        SBLogSync("ACT run shortcut %s", val);
        // 1.6.18：先核对设备真实名单，模型编的名字直接回一句，绝不交给 springcuts 去挂
        if (!SBShortcutExists(val)) {
            SBLogSync("ACT shortcut missing %s", val);
            char msg[640];
            snprintf(msg, sizeof msg, "设备上没有「%.60s」这条快捷指令", val);
            SBSayAsync(msg, conn);
            return 1;
        }
        return SBShortcutRunNamed(val, conn) ? 1 : 0;
    }
    if (!strcmp(act, "app")) {
        if (!sbJsonStr(brace, "\"name\"", 6, val, sizeof val) || !val[0]) return 0;
        SBLogSync("ACT run app %s", val);
        return sbActDispatch(val, 0, conn);
    }
    if (!strcmp(act, "url")) {
        if (!sbJsonStr(brace, "\"value\"", 7, val, sizeof val) || !val[0]) return 0;
        SBLogSync("ACT run url %s", val);
        return sbActDispatch(val, 1, conn);
    }
    if (!strcmp(act, "clip")) {
        id clip = sbClipText();
        const char *cs = clip ? (const char *)SBMsgC(clip, "UTF8String") : NULL;
        if (!cs || !*cs) {
            SBSayAsync("剪贴板里没有文字", conn);
            return 1;
        }
        SBLogSync("ACT clip len=%lu", (unsigned long)strlen(cs));
        // 带着剪贴板内容重开一轮：走正常请求，答案照常上屏朗读
        size_t need = strlen(cs) + 1200;
        char *buf = calloc(1, need);
        if (!buf) { SBSayAsync("剪贴板太长了", conn); return 1; }
        const char *q = (job && job->prompt) ? (const char *)SBMsgC(job->prompt, "UTF8String") : "";
        snprintf(buf, need,
                 "我之前问的是：%.400s\n我剪贴板里的文字是：%.900s\n请结合这段剪贴板内容直接回答我原来的问题。",
                 q ? q : "", cs);
        id np = SBStr(buf);
        free(buf);
        if (np) SBRequest(np, conn);
        else SBSayAsync("没能读到剪贴板", conn);
        return 1;
    }
    if (!strcmp(act, "remember")) {
        if (!sbJsonStr(brace, "\"text\"", 6, val, sizeof val) || !val[0]) {
            SBLogSync("ACT remember empty");
            return 0;
        }
        sbMemAdd(val);
        SBSayAsync("记住了", conn);
        return 1;
    }
    SBLogSync("ACT unsupported %s", act);
    return 0;
}

// 1.6.19 打断：本轮在途时，一句短口令要能把它掐掉。
// 实现上就是「放行存下的原生回执」——1.5.4 已验证回执一放，UI 认为本轮已了结，
// 0.3 秒内 viewWillDisappear，朗读随之停止；同时 g_gen++ 让还在路上的答案作废。
static const char *kStopWords[] = {
    "停", "停止", "停下", "停一下", "别念了", "别说了", "不要念了", "安静",
    "闭嘴", "取消", "算了", "不用了", "退出", "结束", NULL
};

BOOL SBInterruptTry(const char *s) {
    if (!g_busy && !g_onScreen) return NO;
    if (!s || !*s) return NO;
    const char *p = SBStripWake(s);
    if (!p || !*p) return NO;
    // 去掉尾部的标点与空格，避免「停。」「停，」这种差异
    // 注意：中文标点是多字节，不能用 char 字面量比较（编译期会报 character too large）
    char buf[64];
    size_t n = 0;
    while (*p && n < sizeof(buf) - 1) {
        if (*p == ' ' || *p == '\t' || *p == ',' || *p == '!' || *p == '?') break;
        if (!strncmp(p, "，", 3) || !strncmp(p, "。", 3) ||
            !strncmp(p, "！", 3) || !strncmp(p, "？", 3)) break;
        buf[n++] = *p++;
    }
    buf[n] = 0;
    if (!n || n > 8) return NO;            // 只认短口令，长句照常往下走
    for (int i = 0; kStopWords[i]; i++) {
        if (!strcmp(buf, kStopWords[i])) {
            SBLogSync("INT stop <%s>", buf);
            g_gen++;                        // 作废在途答案
            g_reqBusy = NO;
            SBAISetPending(NO);
            g_onScreen = NO;
            SBFlushHeldReply();             // 结束本轮 → 关窗 → 停念
            return YES;
        }
    }
    return NO;
}

static void SBRequest(id text, id conn) {
    // 1.6.18：上一轮如果挂着超过 25 秒（快捷指令卡住、网络没回来），先强拆，别让后面全部丢请求
    if (g_busy && g_pendAt && time(NULL) - g_pendAt > 25) {
        SBLogSync("REQ stale reset pend=%lds", (long)(time(NULL) - g_pendAt));
        SBAISetPending(NO);
    }
    if (g_busy || g_reqBusy) {
        // 1.6.25：上轮还没答完用户又说了一句 —— 当“改口”处理，作废旧轮开新轮。
        // 原来的做法是 busy drop，那新句就白说了，这一轮只能让系统自己答。
        // 但 2 秒内的重复触发仍按抖动丢弃，避免把自己打断。
        if (g_pendAt && time(NULL) - g_pendAt < 2) { SBLog("REQ busy drop"); return; }
        SBLogSync("REQ takeover new q pend=%lds", g_pendAt ? (long)(time(NULL) - g_pendAt) : -1L);
        SBNetCancel();
        SBFlushHeldReply();
        g_busy = NO;
        g_reqBusy = NO;
    }
    g_reqBusy = YES;
    SBJob *job = calloc(1, sizeof(SBJob));
    if (!job) return;
    const char *cc = conn ? class_getName(object_getClass(conn)) : "(nil)";
    SBLogSync("REQ conn=%p cls=%s", (void *)conn, cc);
    job->conn = SBMsgC(conn, "retain");
    job->prompt = SBMsgC(text, "copy");
    job->gen = ++g_gen;
    g_busy = YES;
    if (g_partRef) { SBMsgC(g_partRef, "release"); g_partRef = NULL; }   // 1.6.14 新一轮清掉上轮 ref

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
    // 1.6.25：被改口作废的旧答案直接丢，而且绝不能清 g_busy——
    // 此时新的一轮已经把它设成 YES，旧 job 晚到一步就会把新轮的保护窗拆掉。
    if (job->gen != g_gen) {
        SBLogSync("RES stale drop gen=%d now=%d", job->gen, g_gen);
        SBMsgC(job->conn, "release");
        if (job->prompt) SBMsgC(job->prompt, "release");
        free(job);
        return;
    }
    g_busy = NO;
    g_reqBusy = NO;
    const char *a = job->answer ? (const char *)SBMsgC(job->answer, "UTF8String") : NULL;
    if (!a || !*a) {
        const char *e = job->err ? (const char *)SBMsgC(job->err, "UTF8String") : "?";
        SBLog("RES fail %s", e);
        // 1.6.5 兜底：AI 失败时把存下的原生回执放行，让 Siri 自己收尾，避免窗口永远在途。
        // 1.6.9：改成自己先说一句失败话术（AI 的 AddViews 提交时会顺带结账），
        // 不再无条件放行原生回答——否则失败就直接念出系统那句，一看就露馅。
        SBSayAsync("抱歉，我这边没有连上，过一会儿再问我一次吧", job->conn);
    } else {
        SBLogSync("RES answer len=%lu +%llums", (unsigned long)strlen(a), SBNetElapsedMs());
        // 1.6.6：先看是不是结构化动作指令（模型按系统提示只会输出一行 JSON）。
        int acted = sbTryAct(a, job->conn, job);
        // 1.6.5：只有真的出了答案才记入上下文（失败轮不进历史，避免污染下一轮）。
        if (!acted && job->gen == g_gen) sbCtxAppend(job->prompt, job->answer);
#if SB_STAGE >= 4 && SB_NET_SUBMIT
        if (!acted) {
            // 1.6.13：首句若已经念过（spoke>0），收尾这条用「全文显示 + 只念剩下的」，
            // 否则全文显示 + 全文念。不再提交 TTS——AddViews 自己会念。
            size_t spoke = SBNetSpokeLen();
            id speak = job->answer;
            char *rest = NULL;
            if (spoke > 0) {
                const char *cs = (const char *)SBMsgC(job->answer, "UTF8String");
                if (cs && strlen(cs) > spoke) {
                    rest = strdup(cs + spoke);
                    if (rest) {
                        speak = SBStr(rest);
                        SBLogSync("ACE rest speak len=%lu", (unsigned long)strlen(rest));
                    }
                } else {
                    speak = nil;   // 整段都念过了，这条只显示不念
                    SBLogSync("ACE rest none");
                }
            }
            id cmd = SBAceAddViewsSplitRef(job->answer, speak, g_partRef);
            if (g_partRef) SBLogSync("ACE ref reuse=%d", cmd ? 1 : 0);
            if (cmd) SBSubmitAce(cmd, job->conn);
            if (rest) free(rest);
        }
#endif
    }
    SBMsgC(job->conn, "release");
    if (job->prompt) SBMsgC(job->prompt, "release");
    free(job);
    // 1.6.25：答案已经呈现，再守 2 秒——系统自己那句往往晚这一两百毫秒才到。
    SBCoolStart(2.0);
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

// ============ 1.6.24：剪贴板本地预判 ============
// 原来的做法是「AI 回 {"action":"clip"} 再重开一轮」，但 AI 看不见剪贴板，
// 最可能的反应是自己编一段；就算回了 JSON，也要作废当前轮、重开窗口，观感很差。
// 改成识别阶段就判断：句子里提到剪贴板，本地读一次、内容直接拼进 prompt，只发一次请求。
// changeCount 未变就复用缓存，避免每句都读、反复弹「允许粘贴」。
static BOOL sbClipWanted(const char *t) {
    static const char *kw[] = { "剪贴板", "粘贴板", "我复制", "刚复制", "复制的内容",
                                "复制的那段", "复制的文字", NULL };
    if (!t) return NO;
    for (int i = 0; kw[i]; i++) if (strstr(t, kw[i])) return YES;
    return NO;
}

static long long g_clipCC = -1;
static char *g_clipCache = NULL;

static id sbClipReadCached(void) {
    Class pbCls = objc_getClass("UIPasteboard");
    if (!pbCls) { SBLogSync("CLIP no class"); return nil; }
    id pb = SBMsgC((id)pbCls, "generalPasteboard");
    if (!pb) { SBLogSync("CLIP no pb"); return nil; }
    long long cc = ((long long (*)(id, SEL))objc_msgSend)(pb, sel_registerName("changeCount"));
    if (cc == g_clipCC && g_clipCache) return SBStr(g_clipCache);
    id s = SBMsgC(pb, "string");
    if (!s) { SBLogSync("CLIP empty"); return nil; }
    const char *cs = (const char *)SBMsgC(s, "UTF8String");
    if (!cs || !*cs) { SBLogSync("CLIP empty"); return nil; }
    free(g_clipCache);
    g_clipCache = strdup(cs);
    g_clipCC = cc;
    return SBStr(cs);
}

// 命中剪贴板意图时，把「剪贴板内容 + 原问题」合成一条 prompt
static id sbClipAugment(const char *t) {
    id clip = sbClipReadCached();
    const char *cs = clip ? (const char *)SBMsgC(clip, "UTF8String") : NULL;
    if (!cs || !*cs) return nil;
    size_t need = strlen(cs) + strlen(t) + 300;
    if (need > 1600) need = 1600;
    char *buf = calloc(1, need);
    if (!buf) return nil;
    snprintf(buf, need, "我剪贴板里的文字是：%.900s\n我的问题是：%.400s\n请结合剪贴板内容直接回答。", cs, t);
    id r = SBStr(buf);
    free(buf);
    SBLogSync("CLIP pre len=%lu", (unsigned long)strlen(cs));
    return r;
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
    // 1.6.19：念读/等答案途中来一句“停”，直接结束本轮（放行回执 → 关窗 → 停念）
    if (SBInterruptTry(t)) return;
    // 1.6.26：跨进程探针（只观察，不影响路由）—— 提到微信就顺手 ping 一次 App 侧
    if (strstr(t, "微信")) SBAppPingAsync("voice");
    // 1.6.69 实验入口（临时）：微信内执行验证。
    // 「微信搜索XXX」→ 打开微信 → 点搜索框 → 写入 XXX → 提交，全程在微信进程内完成。
    // 命中时不进 AI、不进原生路由，直接执行并把每一步结果写日志。
    {
        const char *s0 = SBStripWake(t);
        if (s0 && strncmp(s0, "微信搜索", strlen("微信搜索")) == 0) {
            const char *q = s0 + strlen("微信搜索");
            while (*q == ' ' || *q == ':' || *q == '：') q++;
            SBLogSync("ACT wx enter q=<%s>", q);
            if (*q) {
                SBOpenAppNamed("微信");
                char cmdb[240];
                snprintf(cmdb, sizeof cmdb, "seq:tap:搜索;type:%.80s;send", q);
                char *plan = strdup(cmdb);
                if (plan) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                        SBAppActAsync(plan);
                        free(plan);
                    });
                }
                return;
            }
        }
    }
    if (SBShortcutTry(text, conn)) return;
    // 1.6.21：系统自己能答的纯查询（天气/时间/日程/电量…）整句放行，交给原生用真实数据作答
    if (SBRouteNativeQuery(text)) return;
    if (SBRouteNative(text)) return;
#if SB_STAGE >= 3
    // 1.6.24：剪贴板类问题在这里就地取内容，一次请求搞定（读不到就按普通问题走）
    if (sbClipWanted(t)) {
        id aug = sbClipAugment(t);
        if (aug) { SBRequest(aug, conn); return; }
    }
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
    // 1.6.26：跨进程通道（SpringBoard 当服务端 + notify 兜底）。失败只记日志，不影响主链。
    SBAppIPCBoot();
    SBTapProbe();
    SBTapWatchBB();
    SBAppHelloWatch();
    // removed
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
