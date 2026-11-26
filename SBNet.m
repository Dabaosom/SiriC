#import "SiriBridge.h"
#include <string.h>

//  L3：SpringBoard 进程内 NSURLSession dataTaskWithRequest:completionHandler:
//  全部类运行时取、字符串运行时构造；每一步同步打点，崩在哪跳一眼看出。

#define SB_URL   "https://apihub.agnes-ai.com/v1/chat/completions"
#define SB_MODEL "agnes-3.0-flash"
#define SB_KEY   "sk-V0QgHosRfr9EIMgHG6SdQX60z5zVq3JXG0zJ4uNfsPxdsmis"

static id sbBuildRequest(id prompt) {
    Class urlCls = objc_getClass("NSURL");
    Class reqCls = objc_getClass("NSMutableURLRequest");
    Class serCls = objc_getClass("NSJSONSerialization");
    if (!urlCls || !reqCls || !serCls) { SBLogSync("NET missing classes"); return nil; }

    SBLogSync("N1 url");
    id url = ((id (*)(id, SEL, id))objc_msgSend)(
        (id)urlCls, sel_registerName("URLWithString:"), SBStr(SB_URL));
    SBLogSync("N1 ok p=%p", (void *)url);

    SBLogSync("N2 req");
    id req = ((id (*)(id, SEL, id))objc_msgSend)(
        (id)reqCls, sel_registerName("requestWithURL:"), url);
    SBLogSync("N2 ok p=%p", (void *)req);
    if (!req) return nil;

    SBLogSync("N3 method");
    ((void (*)(id, SEL, id))objc_msgSend)(req, sel_registerName("setHTTPMethod:"), SBStr("POST"));
    SBLogSync("N3 ok");

    SBLogSync("N4 timeout");
    ((void (*)(id, SEL, double))objc_msgSend)(req, sel_registerName("setTimeoutInterval:"), 15.0);
    SBLogSync("N4 ok");

    SBLogSync("N5 hdr");
    ((void (*)(id, SEL, id, id))objc_msgSend)(req, sel_registerName("setValue:forHTTPHeaderField:"),
        SBStr("application/json"), SBStr("Content-Type"));
    {
        char hdr[256];
        snprintf(hdr, sizeof hdr, "Bearer %s", SB_KEY);
        ((void (*)(id, SEL, id, id))objc_msgSend)(req, sel_registerName("setValue:forHTTPHeaderField:"),
            SBStr(hdr), SBStr("Authorization"));
    }
    SBLogSync("N5 ok");

    SBLogSync("N6 json");
    id msgDict = SBDict2(SBStr("user"), SBStr("role"), prompt, SBStr("content"));
    id msgs = SBArr1(msgDict);
    id body = SBDict2(SBStr(SB_MODEL), SBStr("model"), msgs, SBStr("messages"));
    id data = ((id (*)(id, SEL, id, unsigned long, void *))objc_msgSend)(
        (id)serCls, sel_registerName("dataWithJSONObject:options:error:"), body, 0UL, NULL);
    SBLogSync("N6 ok p=%p", (void *)data);
    if (!data) return nil;

    SBLogSync("N7 body");
    ((void (*)(id, SEL, id))objc_msgSend)(req, sel_registerName("setHTTPBody:"), data);
    SBLogSync("N7 ok");
    return req;
}

static id sbParseAnswer(id data, id *errOut) {
    if (!data) { *errOut = SBStr("empty"); return nil; }
    SBLogSync("P1 data");
    Class serCls = objc_getClass("NSJSONSerialization");
    id json = ((id (*)(id, SEL, id, unsigned long, void *))objc_msgSend)(
        (id)serCls, sel_registerName("JSONObjectWithData:options:error:"), data, 0UL, NULL);
    SBLogSync("P1 ok p=%p", (void *)json);
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

typedef struct { id prompt; SBNetFn fn; void *ctx; } SBNetJob;

// 本 dylib 里 block 字面量的 isa / invoke 都是编译期数据 fixup，被 ObjC 侧 copy 就炸。
// 因此不使用任何 block 字面量：运行时手工拼一个 global block 结构，
// isa 从 objc_getClass 取，invoke 用代码相对地址（运行时算，不依赖 fixup）。

typedef struct { unsigned long reserved; unsigned long size; void *copy; void *dispose; } SBBlkDesc;
typedef struct {
    void *isa;
    int flags;
    int reserved;
    void *invoke;
    SBBlkDesc *desc;
} SBBlk;

static SBBlk g_blk;
static SBBlkDesc g_desc;
static SBNetJob *g_job = NULL;

static void sbBlockInvoke(void *blkSelf, id data, id resp, id e) {
    SBNetJob *job = g_job;
    if (!job) { SBLog("NET blk no job"); return; }
    id err = nil, ans = nil;
    if (e) {
        err = SBMsgC(e, "localizedDescription");
    } else {
        long code = resp ? ((long (*)(id, SEL))objc_msgSend)(resp, sel_registerName("statusCode")) : 0;
        unsigned long bytes = data ? ((unsigned long (*)(id, SEL))objc_msgSend)(
            data, sel_registerName("length")) : 0;
        SBLogSync("NET http=%ld bytes=%lu", code, bytes);
        ans = sbParseAnswer(data, &err);
    }
    g_job = NULL;
    if (job->fn) job->fn(job->ctx, ans, err);
    SBMsgC(job->prompt, "release");
    free(job);
}

static void *sbMakeGlobalBlock(void) {
    Class k = objc_getClass("__NSGlobalBlock__");
    if (!k) k = objc_getClass("__NSConcreteGlobalBlock");
    if (!k) return NULL;
    g_desc.reserved = 0;
    g_desc.size = sizeof(SBBlk);
    g_desc.copy = NULL;
    g_desc.dispose = NULL;
    g_blk.isa = (void *)k;
    g_blk.flags = 0x10000000;   // BLOCK_IS_GLOBAL
    g_blk.reserved = 0;
    g_blk.invoke = (void *)sbBlockInvoke;
    g_blk.desc = &g_desc;
    return &g_blk;
}

void SBNetPost(id prompt, SBNetFn fn, void *ctx) {
    if (!prompt) { if (fn) fn(ctx, nil, SBStr("empty prompt")); return; }

    id req = sbBuildRequest(prompt);
    if (!req) { if (fn) fn(ctx, nil, SBStr("build request")); return; }

    SBNetJob *job = calloc(1, sizeof(SBNetJob));
    if (!job) { if (fn) fn(ctx, nil, SBStr("no mem")); return; }
    job->prompt = SBMsgC(prompt, "retain");
    job->fn = fn;
    job->ctx = ctx;

    const char *p = (const char *)SBMsgC(prompt, "UTF8String");
    SBLogSync("N8 session (prompt len=%lu)", p ? (unsigned long)strlen(p) : 0UL);
    Class sessCls = objc_getClass("NSURLSession");
    id session = ((id (*)(id, SEL))objc_msgSend)((id)sessCls, sel_registerName("sharedSession"));
    SBLogSync("N8 ok p=%p", (void *)session);

    // 9a：不带 block 建任务（CFNetwork 本体对照）
    SBLogSync("N9a task-nohandler");
    id task0 = ((id (*)(id, SEL, id))objc_msgSend)(
        session, sel_registerName("dataTaskWithRequest:"), req);
    SBLogSync("N9a ok p=%p", (void *)task0);

    // 9b：带运行时构造的 global block
    SBLogSync("N9b task-handler");
    void *blk = sbMakeGlobalBlock();
    SBLogSync("N9b blk=%p", blk);
    if (!blk) { SBLogSync("N9b no block class"); return; }
    g_job = job;
    id task = ((id (*)(id, SEL, id, void *))objc_msgSend)(
        session, sel_registerName("dataTaskWithRequest:completionHandler:"), req, blk);
    SBLogSync("N9b ok p=%p", (void *)task);

    SBLogSync("N10 resume");
    ((void (*)(id, SEL))objc_msgSend)(task, sel_registerName("resume"));
    SBLogSync("N10 ok");
}
