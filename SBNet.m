#import "SiriBridge.h"

//  L3：只走 NSURLSession（com.apple.siri 内已实证 200）。
//  SpringBoard 内 POST 必崩，因此本插件不注入 SpringBoard，也就不留这条死路。

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
    req.HTTPBody = [d dataUsingEncoding:NSUTF8StringEncoding];
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

void SBNetPost(NSString *prompt, SBNetFn fn, void *ctx) {
    if (!prompt.length) { if (fn) fn(ctx, nil, @"empty prompt"); return; }
    NSURLRequest *req = SBBuildRequest(prompt);
    if (!req) { if (fn) fn(ctx, nil, @"build request"); return; }

    SBLog(@"NET send len=%lu", (unsigned long)prompt.length);
    NSURLSession *session = [NSURLSession sharedSession];
    [[session dataTaskWithRequest:req
               completionHandler:^(NSData *data, NSURLResponse *resp, NSError *e) {
        NSString *err = nil;
        NSString *ans = nil;
        if (e) err = e.localizedDescription;
        else ans = SBParseAnswer(data, &err);
        if (fn) fn(ctx, ans, err);
    }] resume];
}
