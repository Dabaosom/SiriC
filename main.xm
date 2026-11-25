#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <pthread.h>
#include <dlfcn.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>

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

static NSString *extract(const NSString *s) {
    NSRange r = [s rangeOfString:@"\"content\":\""];
    if (r.location == NSNotFound) return nil;
    NSUInteger i = r.location + r.length;
    NSMutableString *out = [NSMutableString string];
    BOOL esc = NO;
    while (i < s.length) {
        unichar c = [s characterAtIndex:i];
        if (esc) {
            if (c == 'n') [out appendString:@"\n"];
            else if (c != 'u') [out appendFormat:@"%C", c];
            esc = NO;
            i++;
            continue;
        }
        if (c == '\\') { esc = YES; i++; continue; }
        if (c == '"') break;
        [out appendFormat:@"%C", c];
        i++;
    }
    return out;
}

static void askAI(NSString *text) {
    setv(@"stage", @"asking");
    NSString *esc = [text stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    esc = [esc stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    NSString *body = [NSString stringWithFormat:
        @"{\"model\":\"%@\",\"messages\":[{\"role\":\"user\",\"content\":\"%@\"}]}", kApiModel, esc];
    NSURL *url = [NSURL URLWithString:[kApiBase stringByAppendingString:@"/v1/chat/completions"]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    [req setHTTPMethod:@"POST"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[@"Bearer " stringByAppendingString:kApiKey] forHTTPHeaderField:@"Authorization"];
    [req setHTTPBody:[body dataUsingEncoding:NSUTF8StringEncoding]];
    [req setTimeoutInterval:25];

    NSURLSessionDataTask *t = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err || !data) { setv(@"stage", err ? @"net-err" : @"net-nodata"); return; }
        NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        NSString *ans = s ? extract(s) : nil;
        if (ans.length) { setv(@"answer", ans); setv(@"stage", @"answer-got"); }
        else { setv(@"answer", @"<none>"); setv(@"stage", @"answer-none"); }
    }];
    [t resume];
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
            NSString *t = [text copy];
            dispatch_async(dispatch_get_global_queue(0, 0), ^{ askAI(t); });
        } else {
            setv(@"text", @"<nil>");
        }
    }
    if (orig_speech) ((void(*)(id, SEL, id))orig_speech)(self, _cmd, arg);
}

static void *worker(void *a) {
    (void)a;
    sleep(3);
    Class cls = objc_getClass("AFConnectionClientServiceDelegate");
    if (!cls) { setv(@"stage", @"cls-null"); return 0; }
    SEL sel = NSSelectorFromString(@"speechRecognized:");
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { setv(@"stage", @"method-null"); return 0; }
    orig_speech = method_getImplementation(m);
    method_setImplementation(m, (IMP)my_speech);
    setv(@"stage", @"hooked");
    return 0;
}

__attribute__((constructor)) static void siri_init(void) {
    pthread_t th;
    if (pthread_create(&th, 0, worker, 0) == 0) pthread_detach(th);
}
