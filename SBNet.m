#import "SiriBridge.h"

//  L3：照 SiriPlus 的做法 —— 进程内 NSURLSession + sharedSession
//  dataTaskWithRequest:completionHandler:，结果回主队列。
//  不引入额外线程/同步请求，保持与原插件同一条路径。

#define SB_URL   @"https://apihub.agnes-ai.com/v1/chat/completions"
#define SB_MODEL @"agnes-3.0-flash"
#define SB_KEY   @"sk-V0QgHosRfr9EIMgHG6SdQX60z5zVq3JXG0zJ4uNfsPxdsmis"

static NSURLRequest *SBBuildRequest(NSString *prompt) {
    NSDictionary *body = @{
        @"model" : SB_MODEL,
        @"messages" : @[ @{ @"role" : @"user", @"content" : prompt ?: @"" } ],
    };
    NSData *d = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    if (!d) { SBLog("NET body fail"); return nil; }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:SB_URL]];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 15.0;
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

void SBNetPost(NSString *prompt, SBNetFn fn, void *ctx) {
    if (!prompt.length) { if (fn) fn(ctx, nil, @"empty prompt"); return; }
    NSURLRequest *req = SBBuildRequest(prompt);
    if (!req) { if (fn) fn(ctx, nil, @"build request"); return; }

    SBNetJob *job = calloc(1, sizeof(SBNetJob));
    if (!job) { if (fn) fn(ctx, nil, @"no mem"); return; }
    job->prompt = [prompt retain];
    job->fn = fn;
    job->ctx = ctx;

    SBLog("NET send len=%lu", (unsigned long)prompt.length);

    NSURLSessionDataTask *task =
        [[NSURLSession sharedSession] dataTaskWithRequest:req
                                        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *e) {
        NSString *err = nil, *ans = nil;
        if (e) {
            err = e.localizedDescription;
        } else {
            NSInteger code = [(NSHTTPURLResponse *)resp statusCode];
            SBLog("NET http=%ld bytes=%lu", (long)code, (unsigned long)data.length);
            ans = SBParseAnswer(data, &err);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (job->fn) job->fn(job->ctx, ans, err);
            [job->prompt release];
            free(job);
        });
    }];
    [task resume];
}
