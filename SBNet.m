#import "SiriBridge.h"
#include <string.h>
#include <time.h>

// 1.6.21 延迟解剖：从「请求发出」起算毫秒，用来分清 3.7 秒里有多少是网络、多少是模型。
static uint64_t g_t0 = 0;
static uint64_t sbNowMs(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000ULL + (uint64_t)(ts.tv_nsec / 1000000);
}
unsigned long long SBNetElapsedMs(void) { return g_t0 ? (unsigned long long)(sbNowMs() - g_t0) : 0ULL; }
static int g_firstByteLogged = 0;

//  L3：SpringBoard 进程内 NSURLSession dataTaskWithRequest:completionHandler:
//  全部类运行时取、字符串运行时构造；每一步同步打点，崩在哪跳一眼看出。

#define SB_URL   "https://apihub.agnes-ai.com/v1/chat/completions"
#define SB_MODEL "agnes-3.0-flash"
#define SB_KEY   "sk-V0QgHosRfr9EIMgHG6SdQX60z5zVq3JXG0zJ4uNfsPxdsmis"
#define SB_MAXTOK 160

// 1.6.23：接口参数外置，改 /var/mobile/Documents/aiassist/sb.conf 即可随时换模型/接口，不用重刷包。
// 格式每行 key=value：model / url / key / max_tokens
#define SB_CONF_PATH "/var/mobile/Documents/aiassist/sb.conf"

static char g_cUrl[256]   = SB_URL;
static char g_cModel[64]  = SB_MODEL;
static char g_cKey[256]   = SB_KEY;
static long long g_cMaxTok = SB_MAXTOK;
static time_t g_confAt = 0;

static void sbLoadConf(void) {
    // 每 10 秒才重读一次，避免每个请求都碰磁盘
    time_t now = time(NULL);
    if (g_confAt && now - g_confAt < 10) return;
    g_confAt = now;
    FILE *f = fopen(SB_CONF_PATH, "r");
    if (!f) { SBLogSync("CONF none (defaults)"); return; }
    char line[300];
    int n = 0;
    while (fgets(line, sizeof line, f)) {
        size_t len = strlen(line);
        while (len && (line[len-1] == '\n' || line[len-1] == '\r')) line[--len] = 0;
        if (!len || line[0] == '#') continue;
        char *eq = strchr(line, '=');
        if (!eq) continue;
        *eq = 0;
        char *k = line, *v = eq + 1;
        while (*k == ' ' || *k == '\t') k++;
        while (*v == ' ' || *v == '\t') v++;
        if (!strcmp(k, "model")) { strncpy(g_cModel, v, sizeof(g_cModel)-1); n++; }
        else if (!strcmp(k, "url")) { strncpy(g_cUrl, v, sizeof(g_cUrl)-1); n++; }
        else if (!strcmp(k, "key")) { strncpy(g_cKey, v, sizeof(g_cKey)-1); n++; }
        else if (!strcmp(k, "max_tokens")) { g_cMaxTok = atoll(v); n++; }
    }
    fclose(f);
    SBLogSync("CONF load n=%d model=%s tok=%lld", n, g_cModel, g_cMaxTok);
}

static int g_stream;   // 1.6.10 流式开关（正式定义在下面的缓冲区块）

static id sbBuildRequest(id prompt) {
    sbLoadConf();
    Class urlCls = objc_getClass("NSURL");
    Class reqCls = objc_getClass("NSMutableURLRequest");
    Class serCls = objc_getClass("NSJSONSerialization");
    if (!urlCls || !reqCls || !serCls) { SBLog("NET missing classes"); return nil; }

    SBLog("N1 url");
    id url = ((id (*)(id, SEL, id))objc_msgSend)(
        (id)urlCls, sel_registerName("URLWithString:"), SBStr(g_cUrl));
    SBLog("N1 ok p=%p", (void *)url);

    SBLog("N2 req");
    id req = ((id (*)(id, SEL, id))objc_msgSend)(
        (id)reqCls, sel_registerName("requestWithURL:"), url);
    SBLog("N2 ok p=%p", (void *)req);
    if (!req) return nil;

    SBLog("N3 method");
    ((void (*)(id, SEL, id))objc_msgSend)(req, sel_registerName("setHTTPMethod:"), SBStr("POST"));
    SBLog("N3 ok");

    SBLog("N4 timeout");
    ((void (*)(id, SEL, double))objc_msgSend)(req, sel_registerName("setTimeoutInterval:"), 15.0);
    SBLog("N4 ok");

    SBLog("N5 hdr");
    ((void (*)(id, SEL, id, id))objc_msgSend)(req, sel_registerName("setValue:forHTTPHeaderField:"),
        SBStr("application/json"), SBStr("Content-Type"));
    {
        char hdr[256];
        snprintf(hdr, sizeof hdr, "Bearer %s", g_cKey);
        ((void (*)(id, SEL, id, id))objc_msgSend)(req, sel_registerName("setValue:forHTTPHeaderField:"),
            SBStr(hdr), SBStr("Authorization"));
    }
    SBLog("N5 ok");

    SBLog("N6 json");
    // 1.6.5：消息数组改为「历史 + 本轮」，历史由 SBCore 维护（最近 4 轮、90 秒内有效）。
    id msgs = SBMessagesFor(prompt);
    if (!msgs) {
        id msgDict = SBDict2(SBStr("user"), SBStr("role"), prompt, SBStr("content"));
        msgs = msgDict ? SBArr1(msgDict) : nil;
    }
    id body = SBDict2(SBStr(g_cModel), SBStr("model"), msgs, SBStr("messages"));
    // 1.6.4：压回答长度。非流式接口下，3000 字要等 8~10 秒、念起来几分钟，
    // 350 tokens 大约 250~400 字，既缩短等待也保证能读完。
    {
        Class numCls = objc_getClass("NSNumber");
        id mt = ((id (*)(id, SEL, long long))objc_msgSend)(
            (id)numCls, sel_registerName("numberWithLongLong:"), (long long)g_cMaxTok);
        id mbody = ((id (*)(id, SEL))objc_msgSend)(body, sel_registerName("mutableCopy"));
        if (mbody && mt) {
            ((void (*)(id, SEL, id, id))objc_msgSend)(mbody, sel_registerName("setObject:forKey:"),
                mt, SBStr("max_tokens"));
            body = mbody;
        }
        SBLogSync("N6 cfg model=%s max_tokens=%lld stream=%d", g_cModel, g_cMaxTok, g_stream);
    }
    if (g_stream && body) {
        // 1.6.10：要求 SSE 增量返回，首句一到就能先开口
        id m2 = ((id (*)(id, SEL))objc_msgSend)(body, sel_registerName("mutableCopy"));
        Class numCls = objc_getClass("NSNumber");
        id yes = numCls ? ((id (*)(id, SEL, BOOL))objc_msgSend)((id)numCls,
            sel_registerName("numberWithBool:"), YES) : nil;
        if (m2 && yes) {
            ((void (*)(id, SEL, id, id))objc_msgSend)(m2, sel_registerName("setObject:forKey:"),
                yes, SBStr("stream"));
            body = m2;
        }
        ((void (*)(id, SEL, id, id))objc_msgSend)(req, sel_registerName("setValue:forHTTPHeaderField:"),
            SBStr("text/event-stream"), SBStr("Accept"));
    }
    id data = ((id (*)(id, SEL, id, unsigned long, void *))objc_msgSend)(
        (id)serCls, sel_registerName("dataWithJSONObject:options:error:"), body, 0UL, NULL);
    SBLog("N6 ok p=%p", (void *)data);
    if (!data) return nil;

    SBLog("N7 body");
    ((void (*)(id, SEL, id))objc_msgSend)(req, sel_registerName("setHTTPBody:"), data);
    SBLog("N7 ok");
    return req;
}

static id sbParseAnswer(id data, id *errOut) {
    if (!data) { *errOut = SBStr("empty"); return nil; }
    SBLog("P1 data");
    Class serCls = objc_getClass("NSJSONSerialization");
    id json = ((id (*)(id, SEL, id, unsigned long, void *))objc_msgSend)(
        (id)serCls, sel_registerName("JSONObjectWithData:options:error:"), data, 0UL, NULL);
    SBLog("P1 ok p=%p", (void *)json);
    if (!SBClassIs(json, "NSDictionary")) { *errOut = SBStr("json"); return nil; }

    id choices = ((id (*)(id, SEL, id))objc_msgSend)(
        json, sel_registerName("objectForKey:"), SBStr("choices"));
    if (!SBClassIs(choices, "NSArray") ||
        ((unsigned long (*)(id, SEL))objc_msgSend)(choices, sel_registerName("count")) == 0) {
        *errOut = SBStr("no choices");
        return nil;
    }
    id first = ((id (*)(id, SEL, unsigned long))objc_msgSend)(
        choices, sel_registerName("objectAtIndex:"), 0UL);
    id msg = ((id (*)(id, SEL, id))objc_msgSend)(
        first, sel_registerName("objectForKey:"), SBStr("message"));
    id content = msg ? ((id (*)(id, SEL, id))objc_msgSend)(
        msg, sel_registerName("objectForKey:"), SBStr("content")) : nil;
    if (!SBClassIs(content, "NSString")) { *errOut = SBStr("no content"); return nil; }
    const char *cs = (const char *)SBMsgC(content, "UTF8String");
    if (!cs || !*cs) { *errOut = SBStr("empty content"); return nil; }
    return content;
}

typedef struct { id prompt; SBNetFn fn; void *ctx; int retried; } SBNetJob;

// completion block 这条路连续三次崩（字面量 / 修 isa / 运行时 global block 都崩），
// 但 dataTaskWithRequest: 不带 block 是好的 —— 说明 CFNetwork 本体可用，
// 炸的是「把 block 交给 CFNetwork 存成 copy 属性」。改用 delegate 回调：
// delegate 是运行时 objc_allocateClassPair 造的真对象，不涉及任何 block。

static id g_data = NULL;      // NSMutableData 累积
static SBNetJob *g_job = NULL;
static id g_session = NULL;
static id g_sharedSession = NULL;   // 1.6.22：复用同一个 session，免掉每次请求的 TCP/TLS 握手
static id g_sharedDelegate = NULL;
static int g_retryDepth = 0;        // 1.6.23：静默重试只做一次

// 1.6.10 流式：SSE 增量解析，首句一到就先交给 TTS 说话，不等整段答案。
static char g_raw[8192];      // 原始响应体（按行扫 data:）
static size_t g_rawLen = 0;
static size_t g_scanOff = 0;  // 已扫到的行末
static char g_acc[8192];      // 拼出来的答案文本
static size_t g_accLen = 0;
static int g_spoke = 0;       // 首句是否已经交出去了
static size_t g_spokeLen = 0; // 已经“说过”的字节数，收尾时只念剩下的

size_t SBNetSpokeLen(void) { return g_spoke ? g_spokeLen : 0; }

// 拼字：把一段 delta 内容接到 g_acc，并在第一句成型时交出去。
static void sbAccAppend(const char *piece, size_t n) {
    if (g_accLen + n >= sizeof(g_acc) - 1) n = sizeof(g_acc) - 1 - g_accLen;
    if (!n) return;
    memcpy(g_acc + g_accLen, piece, n);
    g_accLen += n;
    g_acc[g_accLen] = 0;
    if (g_spoke) return;

    // 动作指令（一行 JSON）绝不能拿去念，见到就放弃“先说话”，留给收尾统一处理
    {
        const char *s = g_acc;
        while (*s == ' ' || *s == '\n' || *s == '\r' || *s == '\t') s++;
        if (*s == '{' || strstr(g_acc, "\"action\"")) {
            g_spoke = 1;
            g_spokeLen = 0;
            SBLogSync("PART skip action");
            return;
        }
    }

    // 找第一句的句末（中英文句号都认），找不到就攒到 80 字节先开口。
    static const char *terms[] = {"。", "！", "？", "\n", "!", "?", "."};
    size_t cut = 0;
    for (size_t i = 0; i < sizeof(terms) / sizeof(terms[0]); i++) {
        const char *p = strstr(g_acc, terms[i]);
        if (p) {
            size_t cand = (size_t)(p - g_acc) + strlen(terms[i]);
            if (!cut || cand < cut) cut = cand;
        }
    }
    if (!cut) {
        if (g_accLen < 80) return;
        cut = 80;
    }
    if (cut > g_accLen) cut = g_accLen;
    char *first = strndup(g_acc, cut);
    if (!first) return;
    g_spoke = 1;
    g_spokeLen = cut;
    SBLogSync("PART speak len=%lu", (unsigned long)cut);
    SBNetPartial(first, g_job ? g_job->ctx : NULL);
    free(first);
}

// 拆一行 SSE：data: {"choices":[{"delta":{"content":"…"}}]}
static void sbSseOne(const char *js, size_t len) {
    (void)len;
    const char *d = strstr(js, "\"delta\"");
    if (!d) return;
    const char *c = strstr(d, "\"content\":\"");
    if (!c) return;
    const char *p = c + 11;
    char buf[1024];
    size_t n = 0;
    while (*p && *p != '"' && n < sizeof(buf) - 1) {
        if (*p == '\\' && p[1]) {
            p++;
            if (*p == 'n') buf[n++] = '\n';
            else if (*p == 't') buf[n++] = '\t';
            else if (*p == 'r') buf[n++] = '\r';
            else if (*p == 'u') {   // \uXXXX 少见到，直接跳过 4 位
                p++;
                for (int k = 0; k < 4 && *p; k++) p++;
                continue;
            } else buf[n++] = *p;
            p++;
        } else {
            buf[n++] = *p++;
        }
    }
    if (n) sbAccAppend(buf, n);
}

static void sbSseScan(void) {
    while (g_scanOff < g_rawLen) {
        size_t end = g_scanOff;
        while (end < g_rawLen && g_raw[end] != '\n') end++;
        if (end >= g_rawLen) break;      // 这一行还没收完，等下一次数据
        size_t off = g_scanOff, ln = end - off;
        g_scanOff = end + 1;
        if (ln < 6 || strncmp(g_raw + off, "data:", 5) != 0) continue;
        sbSseOne(g_raw + off + 5, ln - 5);
    }
}

static void sbStreamFeed(id data) {
    if (!data) return;
    if (!g_firstByteLogged) { g_firstByteLogged = 1; SBLogSync("NET b1 +%llums", SBNetElapsedMs()); }
    unsigned long n = ((unsigned long (*)(id, SEL))objc_msgSend)(data, sel_registerName("length"));
    const void *b = ((const void *(*)(id, SEL))objc_msgSend)(data, sel_registerName("bytes"));
    if (!b || !n) return;
    if (g_rawLen + n >= sizeof(g_raw)) n = sizeof(g_raw) - g_rawLen - 1;
    if (!n) return;
    memcpy(g_raw + g_rawLen, b, n);
    g_rawLen += n;
    g_raw[g_rawLen] = 0;
    sbSseScan();
}

// 同步模式（1.4.5）：等待方在识别链里阻塞，delegate 队列上解析完直接放行。
static BOOL g_sync = NO;
static dispatch_semaphore_t g_sem = NULL;
static id g_syncAns = NULL;
static id g_syncErr = NULL;

static void sbNetFinish(id task) {
    SBNetJob *job = g_job;
    g_job = NULL;
    unsigned long bytes = g_data ? ((unsigned long (*)(id, SEL))objc_msgSend)(
        g_data, sel_registerName("length")) : 0;
    SBLog("NET done bytes=%lu job=%d", bytes, job ? 1 : 0);
    if (!job) {
        if (g_data) { SBMsgC(g_data, "release"); g_data = NULL; }
        return;   // 迟到的回调（等待方已超时）
    }
    id err = nil, ans = nil;
    if (g_stream && g_accLen) {
        // 1.6.10：流式收尾，答案已经在 C 缓冲里拼好了，直接转 NSString
        Class scls = objc_getClass("NSString");
        ans = ((id (*)(id, SEL, const char *))objc_msgSend)(
            (id)scls, sel_registerName("stringWithUTF8String:"), g_acc);
        SBLog("NET acc len=%lu", (unsigned long)g_accLen);
    }
    if (!ans && bytes) ans = sbParseAnswer(g_data, &err);   // 服务端没走 SSE 时退回整包解析
    if (!ans && !err) err = bytes ? SBStr("empty content") : SBStr("no data");
    g_stream = 0;

    // 1.6.23 静默重试：一个字都没收到就再试一次（服务端偶发卡顿，实测首字节会跳到 5 秒以上）。
    // 已经收过内容的不重试，否则会把半句话重复念一遍；只重试一次，用 g_retryDepth 记账。
    if (!ans && !g_sync && g_retryDepth == 0 && g_rawLen == 0) {
        SBNetFn fn = job->fn;
        void *ctx = job->ctx;
        id prompt = SBMsgC(job->prompt, "retain");
        SBLog("NET retry attempt");
        free(job);
        if (g_data) { SBMsgC(g_data, "release"); g_data = NULL; }
        g_retryDepth = 1;
        SBNetPost(prompt, fn, ctx);
        SBMsgC(prompt, "release");
        return;
    }
    g_retryDepth = 0;

    if (job->fn) job->fn(job->ctx, ans, err);
    if (g_sync) {
        g_syncAns = ans ? SBMsgC(ans, "retain") : nil;
        g_syncErr = err ? SBMsgC(err, "retain") : nil;
    }
    SBMsgC(job->prompt, "release");
    free(job);
    if (g_data) { SBMsgC(g_data, "release"); g_data = NULL; }
    if (g_sync && g_sem) { dispatch_semaphore_signal(g_sem); }
}

// -URLSession:dataTask:didReceiveData:
static void sbDidReceiveData(id self, SEL _cmd, id session, id task, id data) {
    if (!data) return;
    if (g_stream) { sbStreamFeed(data); return; }
    if (!g_data) {
        Class cls = objc_getClass("NSMutableData");
        g_data = ((id (*)(id, SEL))objc_msgSend)((id)cls, sel_registerName("data"));
        SBMsgC(g_data, "retain");
    }
    if (g_data) ((void (*)(id, SEL, id))objc_msgSend)(
        g_data, sel_registerName("appendData:"), data);
}

// -URLSession:task:didCompleteWithError:
static void sbNetFinishMain(void *ctx);

static void sbDidComplete(id self, SEL _cmd, id session, id task, id error) {
    if (g_sync) { SBLog("NET didComplete sync"); sbNetFinish(nil); return; }
    SBLog("NET didComplete");
    dispatch_async_f(dispatch_get_main_queue(), task, (void (*)(void *))sbNetFinishMain);
}

static void sbNetFinishMain(void *ctx) {
    (void)ctx;
    sbNetFinish(nil);
}

static id sbMakeDelegate(void) {
    Class base = objc_getClass("NSObject");
    if (!base) return nil;
    Class cls = objc_allocateClassPair(base, "SBNetDelegate0", 0);
    if (!cls) {
        cls = objc_getClass("SBNetDelegate0");
        if (!cls) return nil;
    } else {
        class_addMethod(cls, sel_registerName("URLSession:dataTask:didReceiveData:"),
                        (IMP)sbDidReceiveData, "v@:@@@");
        class_addMethod(cls, sel_registerName("URLSession:task:didCompleteWithError:"),
                        (IMP)sbDidComplete, "v@:@@@");
        objc_registerClassPair(cls);
    }
    id obj = ((id (*)(id, SEL))objc_msgSend)((id)cls, sel_registerName("alloc"));
    return ((id (*)(id, SEL))objc_msgSend)(obj, sel_registerName("init"));
}

void SBNetPost(id prompt, SBNetFn fn, void *ctx) {
    if (!prompt) { if (fn) fn(ctx, nil, SBStr("empty prompt")); return; }

    // 1.6.10：本轮走流式，清空增量缓冲
    g_stream = 1;
    g_rawLen = 0; g_raw[0] = 0;
    g_scanOff = 0;
    g_accLen = 0; g_acc[0] = 0;
    g_spoke = 0; g_spokeLen = 0;
    g_firstByteLogged = 0;
    g_t0 = sbNowMs();
    SBLogSync("NET go");

    id req = sbBuildRequest(prompt);
    if (!req) { if (fn) fn(ctx, nil, SBStr("build request")); return; }

    SBNetJob *job = calloc(1, sizeof(SBNetJob));
    if (!job) { if (fn) fn(ctx, nil, SBStr("no mem")); return; }
    job->prompt = SBMsgC(prompt, "retain");
    job->fn = fn;
    job->ctx = ctx;

    const char *p = (const char *)SBMsgC(prompt, "UTF8String");
    SBLog("D1 delegate (prompt len=%lu)", p ? (unsigned long)strlen(p) : 0UL);

    // 1.6.22：第一次建 session，之后复用（同一 session 会复用 TCP/TLS 连接）。
    // 实测首字节 1.5~5.4 秒，握手这部分每次都在白付。
    id session = g_sharedSession;
    if (!session) {
        id del = sbMakeDelegate();
        SBLog("D1 ok p=%p", (void *)del);
        if (!del) { g_job = NULL; free(job); if (fn) fn(ctx, nil, SBStr("no delegate")); return; }
        g_sharedDelegate = SBMsgC(del, "retain");

        SBLog("D2 config");
        Class cfgCls = objc_getClass("NSURLSessionConfiguration");
        id cfg = ((id (*)(id, SEL))objc_msgSend)((id)cfgCls,
                    sel_registerName("defaultSessionConfiguration"));
        SBLog("D2 ok p=%p", (void *)cfg);

        SBLog("D3 session");
        Class sessCls = objc_getClass("NSURLSession");
        session = ((id (*)(id, SEL, id, id, id))objc_msgSend)((id)sessCls,
            sel_registerName("sessionWithConfiguration:delegate:delegateQueue:"),
            cfg, g_sharedDelegate, nil);
        SBLog("D3 ok p=%p", (void *)session);
        if (!session) { free(job); if (fn) fn(ctx, nil, SBStr("no session")); return; }
        g_sharedSession = SBMsgC(session, "retain");
    } else {
        SBLog("D3 reuse p=%p", (void *)session);
    }
    if (g_session) SBMsgC(g_session, "release");
    g_session = SBMsgC(session, "retain");

    SBLog("D4 task");
    g_job = job;
    id task = ((id (*)(id, SEL, id))objc_msgSend)(
        session, sel_registerName("dataTaskWithRequest:"), req);
    SBLog("D4 ok p=%p", (void *)task);

    SBLog("D5 resume");
    ((void (*)(id, SEL))objc_msgSend)(task, sel_registerName("resume"));
    SBLog("D5 ok");
}

// 同步版（1.4.5）：和 SiriPlus 一样，在识别链里就把答案拿到手。
// 复用同一套 delegate 收数据路径（不用 completion block），只是等在这里。
id SBNetPostSync(id prompt, double timeoutSec, id *errOut) {
    if (errOut) *errOut = nil;
    if (!prompt) { if (errOut) *errOut = SBStr("empty prompt"); return nil; }
    g_stream = 0;   // 同步路径不用流式（调用方要的是整包）

    id req = sbBuildRequest(prompt);
    if (!req) { if (errOut) *errOut = SBStr("build request"); return nil; }

    SBNetJob *job = calloc(1, sizeof(SBNetJob));
    if (!job) { if (errOut) *errOut = SBStr("no mem"); return nil; }
    job->prompt = SBMsgC(prompt, "retain");

    const char *p = (const char *)SBMsgC(prompt, "UTF8String");
    SBLogSync("S1 delegate (prompt len=%lu)", p ? (unsigned long)strlen(p) : 0UL);
    id del = sbMakeDelegate();
    if (!del) { SBMsgC(job->prompt, "release"); free(job); if (errOut) *errOut = SBStr("no delegate"); return nil; }

    Class cfgCls = objc_getClass("NSURLSessionConfiguration");
    id cfg = ((id (*)(id, SEL))objc_msgSend)((id)cfgCls,
                sel_registerName("defaultSessionConfiguration"));
    Class sessCls = objc_getClass("NSURLSession");
    id session = ((id (*)(id, SEL, id, id, id))objc_msgSend)((id)sessCls,
        sel_registerName("sessionWithConfiguration:delegate:delegateQueue:"), cfg, del, nil);
    if (!session) { SBMsgC(job->prompt, "release"); free(job); if (errOut) *errOut = SBStr("no session"); return nil; }
    if (g_session) SBMsgC(g_session, "release");
    g_session = SBMsgC(session, "retain");

    g_syncAns = nil; g_syncErr = nil;
    g_sem = dispatch_semaphore_create(0);
    g_sync = YES;
    g_job = job;

    id task = ((id (*)(id, SEL, id))objc_msgSend)(session, sel_registerName("dataTaskWithRequest:"), req);
    SBLogSync("S2 resume wait=%dms", (int)(timeoutSec * 1000.0));
    ((void (*)(id, SEL))objc_msgSend)(task, sel_registerName("resume"));

    dispatch_time_t dl = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeoutSec * 1e9));
    long rc = dispatch_semaphore_wait(g_sem, dl);
    g_sync = NO;
    g_sem = NULL;

    if (rc != 0) {
        SBLogSync("S3 timeout");
        if (g_job) { SBMsgC(g_job->prompt, "release"); free(g_job); g_job = NULL; }
        ((void (*)(id, SEL))objc_msgSend)(session, sel_registerName("invalidateAndCancel"));
        if (g_data) { SBMsgC(g_data, "release"); g_data = NULL; }
        if (errOut) *errOut = SBStr("timeout");
        return nil;
    }

    id ans = g_syncAns, err = g_syncErr;
    g_syncAns = nil; g_syncErr = nil;
    SBLogSync("S3 ok ans=%d", ans ? 1 : 0);
    ((void (*)(id, SEL))objc_msgSend)(session, sel_registerName("finishTasksAndInvalidate"));
    if (errOut) *errOut = err;
    return ans;   // 已 retain，所有权交给调用方
}
