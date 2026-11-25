#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static NSString *const kDomain   = @"com.doubao.siriaigh";
static NSString *const kApiBase  = @"https://apihub.agnes-ai.com";
static NSString *const kApiKey   = @"sk-V0QgHosRfr9EIMgHG6SdQX60z5zVq3JXG0zJ4uNfsPxdsmis";
static NSString *const kApiModel = @"agnes-3.0-flash";

static void setv(NSString *k, NSString *v) {
    if (!v) v = @"";
    CFPreferencesSetAppValue((__bridge CFStringRef)k, (__bridge CFStringRef)v,
                             (__bridge CFStringRef)kDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
}

static void post(NSString *text, NSString *url, NSString *body, void (^done)(NSString *)) {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    [req setHTTPMethod:@"POST"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[@"Bearer " stringByAppendingString:kApiKey] forHTTPHeaderField:@"Authorization"];
    [req setHTTPBody:[body dataUsingEncoding:NSUTF8StringEncoding]];
    [req setTimeoutInterval:30];

    NSURLSessionDataTask *t = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err || !data) { done(nil); return; }
        NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!s) { done(nil); return; }
        NSRange r = [s rangeOfString:@"\"content\":\""];
        if (r.location == NSNotFound) { done(nil); return; }
        NSUInteger i = r.location + r.length;
        NSMutableString *out = [NSMutableString string];
        BOOL esc = NO;
        while (i < s.length) {
            unichar c = [s characterAtIndex:i];
            if (esc) {
                if (c == 'n') [out appendString:@"\n"];
                else if (c == 'u') { i += 4; }
                else [out appendFormat:@"%C", c];
                esc = NO;
                i++;
                continue;
            }
            if (c == '\\') { esc = YES; i++; continue; }
            if (c == '"') break;
            [out appendFormat:@"%C", c];
            i++;
        }
        done(out.copy);
    }];
    [t resume];
}

static NSString *buildBody(NSString *text) {
    NSString *esc = [text stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    esc = [esc stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    esc = [esc stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
    return [NSString stringWithFormat:
        @"{\"model\":\"%@\",\"messages\":[{\"role\":\"user\",\"content\":\"%@\"}]}", kApiModel, esc];
}

static void askAI(NSString *text) {
    setv(@"stage", @"asking");
    NSString *url  = [kApiBase stringByAppendingString:@"/v1/chat/completions"];
    NSString *body = buildBody(text);
    post(text, url, body, ^(NSString *ans) {
        if (ans.length) {
            setv(@"answer", ans);
            setv(@"stage", @"answer-ok");
        } else {
            setv(@"answer", @"<none>");
            setv(@"stage", @"answer-none");
        }
    });
}

static IMP orig_speech = NULL;

static void my_speech(id self, SEL _cmd, id arg) {
    @autoreleasepool {
        setv(@"stage", @"hit");
        NSString *text = nil;
        @try {
            id best = [arg performSelector:NSSelectorFromString(@"af_bestTextInterpretation")];
            if ([best isKindOfClass:[NSString class]]) text = best;
        } @catch (NSException *e) { text = nil; }
        if (text.length) {
            setv(@"text", text);
            dispatch_async(dispatch_get_global_queue(0, 0), ^{ askAI(text); });
        } else {
            setv(@"text", @"<nil>");
        }
    }
    if (orig_speech) ((void(*)(id, SEL, id))orig_speech)(self, _cmd, arg);
}

static void installHook(void) {
    Class cls = objc_getClass("AFConnectionClientServiceDelegate");
    if (!cls) { setv(@"stage", @"cls-null"); return; }
    SEL sel = NSSelectorFromString(@"speechRecognized:");
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { setv(@"stage", @"method-null"); return; }
    orig_speech = method_getImplementation(m);
    method_setImplementation(m, (IMP)my_speech);
    setv(@"stage", @"hooked");
}

__attribute__((constructor)) static void siric_init(void) {
    // 绝不在 dyld 初始化期碰 CF/objc：等 SpringBoard 起来再挂
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ installHook(); });
}
