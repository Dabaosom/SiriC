#import "SiriBridge.h"
#include <pthread.h>

//  L3：SpringBoard 内 NSURLSession 发 POST 必崩（0x105），
//  改用 +[NSURLConnection sendSynchronousRequest:] 跑独立 pthread（已实证可用）。

#define SB_URL   @"https://apihub.agnes-ai.com/v1/chat/completions"
#define SB_MODEL @"agnes-3.0-flash"
#define SB_KEY   @"sk-V0QgHosRfr9EIMgHG6SdQX60z5zVq3JXG0zJ4uNfsPxdsmis"

static NSURLRequest *SBBuildRequest(NSString *prompt) {
    NSDictionary *body = @{
        @"model" : SB_MODEL,
        @"messages" : @[ @{ @"role" : @"user", @"content" : prompt ?: @"" } ],
    };
    NSData *d = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    if (!d) return nil;

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:SB_URL]];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 8.0;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", SB_KEY]
         forHTTPHeaderField:@"Authorization"];
    req.HTTPBody = d;
    return req;
}

static NSString *SBParseAnswer(NSData *data, NSString **errOut) {
    if (!data.length) { if (errOut) *errOut = @"empty"; return nil; }
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) { if (errOut) *errOut = @"json"; return nil; }

    NSArray *choices = ((NSDictionary *)json)[@"choices"];
    if (![choices isKindOfClass:[NSArray class]] || !choices.count) {
        if (errOut) *errOut = @"no choices";
        return nil;
    }
    id msg = ((NSDictionary *)choices[0])[@"message"];
    id content = [msg isKindOfClass:[NSDictionary class]] ? ((NSDictionary *)msg)[@"content"] : nil;
    if ([content isKindOfClass:[NSArray class]]) {
        NSMutableString *s = [NSMutableString string];
        for (id part in (NSArray *)content) {
            if ([part isKindOfClass:[NSDictionary class]]) {
                id txt = ((NSDictionary *)part)[@"text"];
                if ([txt isKindOfClass:[NSString class]]) [s appendString:txt];
            }
        }
        content = s;
    }
    if (![content isKindOfClass:[NSString class]] || ![content length]) {
        if (errOut) *errOut = @"no content";
        return nil;
    }
    return content;
}

typedef struct { id prompt; SBNetFn fn; void *ctx; } SBNetJob;

static void *SBNetThread(void *arg) {
    SBNetJob *job = (SBNetJob *)arg;
    NSString *prompt = job->prompt;
    NSURLRequest *req = SBBuildRequest(prompt);
    NSString *err = nil, *ans = nil;
    if (!req) {
        err = @"build request";
    } else {
        NSURLResponse *resp = nil;
        NSError *e = nil;
        NSData *data = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        data = [NSURLConnection sendSynchronousRequest:req returningResponse:&resp error:&e];
#pragma clang diagnostic pop
        if (e) err = e.localizedDescription;
        else ans = SBParseAnswer(data, &err);
    }
    if (job->fn) job->fn(job->ctx, ans, err);
    [job->prompt release];
    free(job);
    return NULL;
}

void SBNetPost(NSString *prompt, SBNetFn fn, void *ctx) {
    if (!prompt.length) { if (fn) fn(ctx, nil, @"empty prompt"); return; }
    SBLog(@"NET send len=%lu", (unsigned long)prompt.length);

    SBNetJob *job = calloc(1, sizeof(SBNetJob));
    if (!job) { if (fn) fn(ctx, nil, @"no mem"); return; }
    job->prompt = [prompt retain];
    job->fn = fn;
    job->ctx = ctx;
    pthread_t th;
    if (pthread_create(&th, NULL, SBNetThread, job) != 0) {
        [job->prompt release];
        free(job);
        if (fn) fn(ctx, nil, @"thread fail");
        return;
    }
    pthread_detach(th);
}
