#import "SiriBridge.h"
#include <string.h>

//  L3：SpringBoard 进程内 NSURLSession dataTaskWithRequest:completionHandler:
//  所有类运行时取，字符串运行时构造（不用字面量）。

#define SB_URL   "https://apihub.agnes-ai.com/v1/chat/completions"
#define SB_MODEL "agnes-3.0-flash"
#define SB_KEY   "sk-V0QgHosRfr9EIMgHG6SdQX60z5zVq3JXG0zJ4uNfsPxdsmis"

static id sbBuildRequest(id prompt) {
    Class urlCls = objc_getClass("NSURL");
    Class reqCls = objc_getClass("NSMutableURLRequest");
    Class serCls = objc_getClass("NSJSONSerialization");
    if (!urlCls || !reqCls || !serCls) { SBLog("NET missing classes"); return nil; }

    id msgDict = SBDict2(SBStr("user"), SBStr("role"), prompt, SBStr("content"));
    id msgs = SBArr1(msgDict);
    id body = SBDict2(SBStr(SB_MODEL), SBStr("model"), msgs, SBStr("messages"));

    NSError *e = nil;
    id data = ((id (*)(id, SEL, id, unsigned long, NSError **))objc_msgSend)(
        (id)serCls, sel_registerName("dataWithJSONObject:options:error:"), body, 0UL, &e);
    if (!data) { SBLog("NET json fail"); return nil; }

    id url = ((id (*)(id, SEL, id))objc_msgSend)(
        (id)urlCls, sel_registerName("URLWithString:"), SBStr(SB_URL));
    id req = ((id (*)(id, SEL, id))objc_msgSend)(
        (id)reqCls, sel_registerName("requestWithURL:"), url);
    if (!req) { SBLog("NET req nil"); return nil; }

    ((void (*)(id, SEL, id))objc_msgSend)(req, sel_registerName("setHTTPMethod:"), SBStr("POST"));
    ((void (*)(id, SEL, double))objc_msgSend)(req, sel_registerName("setTimeoutInterval:"), 15.0);
    ((void (*)(id, SEL, id, id))objc_msgSend)(req, sel_registerName("setValue:forHTTPHeaderField:"),
        SBStr("application/json"), SBStr("Content-Type"));
    {
        char hdr[256];
        snprintf(hdr, sizeof hdr, "Bearer %s", SB_KEY);
        ((void (*)(id, SEL, id, id))objc_msgSend)(req, sel_registerName("setValue:forHTTPHeaderField:"),
            SBStr(hdr), SBStr("Authorization"));
    }
    ((void (*)(id, SEL, id))objc_msgSend)(req, sel_registerName("setHTTPBody:"), data);
    return req;
}

static id sbParseAnswer(id data, id *errOut) {
    if (!data) { *errOut = SBStr("empty"); return nil; }
    Class serCls = objc_getClass("NSJSONSerialization");
    id json = ((id (*)(id, SEL, id, unsigned long, NSError **))objc_msgSend)(
        (id)serCls, sel_registerName("JSONObjectWithData:options:error:"), data, 0UL, NULL);
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
    SBLog("NET send len=%lu", p ? (unsigned long)strlen(p) : 0UL);

    Class sessCls = objc_getClass("NSURLSession");
    id session = ((id (*)(id, SEL))objc_msgSend)((id)sessCls, sel_registerName("sharedSession"));

    id task = ((id (*)(id, SEL, id, void (^)(id, id, id)))objc_msgSend)(
        session, sel_registerName("dataTaskWithRequest:completionHandler:"), req,
        ^(id data, id resp, id e) {
            id err = nil, ans = nil;
            if (e) {
                err = SBMsgC(e, "localizedDescription");
            } else {
                long code = resp ? ((long (*)(id, SEL))objc_msgSend)(resp, sel_registerName("statusCode")) : 0;
                unsigned long bytes = data ? ((unsigned long (*)(id, SEL))objc_msgSend)(
                    data, sel_registerName("length")) : 0;
                SBLog("NET http=%ld bytes=%lu", code, bytes);
                ans = sbParseAnswer(data, &err);
            }
            if (job->fn) job->fn(job->ctx, ans, err);
            SBMsgC(job->prompt, "release");
            free(job);
        });
    ((void (*)(id, SEL))objc_msgSend)(task, sel_registerName("resume"));
}
