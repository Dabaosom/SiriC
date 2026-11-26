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

// completion block 这条路连续三次崩（字面量 / 修 isa / 运行时 global block 都崩），
// 但 dataTaskWithRequest: 不带 block 是好的 —— 说明 CFNetwork 本体可用，
// 炸的是「把 block 交给 CFNetwork 存成 copy 属性」。改用 delegate 回调：
// delegate 是运行时 objc_allocateClassPair 造的真对象，不涉及任何 block。

static id g_data = NULL;      // NSMutableData 累积
static SBNetJob *g_job = NULL;
static id g_session = NULL;

static void sbNetFinish(id task) {
    SBNetJob *job = g_job;
    g_job = NULL;
    if (!job) return;
    id err = nil, ans = nil;
    unsigned long bytes = g_data ? ((unsigned long (*)(id, SEL))objc_msgSend)(
        g_data, sel_registerName("length")) : 0;
    SBLogSync("NET done bytes=%lu", bytes);
    if (bytes) ans = sbParseAnswer(g_data, &err);
    else err = SBStr("no data");
    if (job->fn) job->fn(job->ctx, ans, err);
    SBMsgC(job->prompt, "release");
    free(job);
    if (g_data) { SBMsgC(g_data, "release"); g_data = NULL; }
}

// -URLSession:dataTask:didReceiveData:
static void sbDidReceiveData(id self, SEL _cmd, id session, id task, id data) {
    if (!data) return;
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

    id req = sbBuildRequest(prompt);
    if (!req) { if (fn) fn(ctx, nil, SBStr("build request")); return; }

    SBNetJob *job = calloc(1, sizeof(SBNetJob));
    if (!job) { if (fn) fn(ctx, nil, SBStr("no mem")); return; }
    job->prompt = SBMsgC(prompt, "retain");
    job->fn = fn;
    job->ctx = ctx;

    const char *p = (const char *)SBMsgC(prompt, "UTF8String");
    SBLogSync("D1 delegate (prompt len=%lu)", p ? (unsigned long)strlen(p) : 0UL);
    id del = sbMakeDelegate();
    SBLogSync("D1 ok p=%p", (void *)del);
    if (!del) { g_job = NULL; free(job); if (fn) fn(ctx, nil, SBStr("no delegate")); return; }

    SBLogSync("D2 config");
    Class cfgCls = objc_getClass("NSURLSessionConfiguration");
    id cfg = ((id (*)(id, SEL))objc_msgSend)((id)cfgCls,
                sel_registerName("defaultSessionConfiguration"));
    SBLogSync("D2 ok p=%p", (void *)cfg);

    SBLogSync("D3 session");
    Class sessCls = objc_getClass("NSURLSession");
    id session = ((id (*)(id, SEL, id, id, id))objc_msgSend)((id)sessCls,
        sel_registerName("sessionWithConfiguration:delegate:delegateQueue:"),
        cfg, del, nil);
    SBLogSync("D3 ok p=%p", (void *)session);
    if (!session) { free(job); if (fn) fn(ctx, nil, SBStr("no session")); return; }
    g_session = SBMsgC(session, "retain");

    SBLogSync("D4 task");
    g_job = job;
    id task = ((id (*)(id, SEL, id))objc_msgSend)(
        session, sel_registerName("dataTaskWithRequest:"), req);
    SBLogSync("D4 ok p=%p", (void *)task);

    SBLogSync("D5 resume");
    ((void (*)(id, SEL))objc_msgSend)(task, sel_registerName("resume"));
    SBLogSync("D5 ok");
}
