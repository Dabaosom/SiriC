#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <pthread.h>
#include <unistd.h>
#include <time.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

/* 本文件刻意不使用任何 @"..." 字面量：
   全部 ObjC 字符串都由 C 字面量经 stringWithUTF8String 在运行期构造。 */

#define PREFDOMAIN "com.doubao.siriaigh"
#define API_URL    "https://apihub.agnes-ai.com/v1/chat/completions"
#define API_KEY    "sk-V0QgHosRfr9EIMgHG6SdQX60z5zVq3JXG0zJ4uNfsPxdsmis"
#define API_MODEL  "agnes-3.0-flash"

static NSString *S(const char *s) {
    if (!s) return [NSString string];
    return [NSString stringWithUTF8String:s];
}

static void setv(const char *k, const char *v) {
    if (!v) v = "";
    CFStringRef key = CFStringCreateWithCString(0, k, kCFStringEncodingUTF8);
    CFStringRef val = CFStringCreateWithCString(0, v, kCFStringEncodingUTF8);
    CFStringRef dom = CFStringCreateWithCString(0, PREFDOMAIN, kCFStringEncodingUTF8);
    CFPreferencesSetAppValue(key, val, dom);
    CFPreferencesAppSynchronize(dom);
    CFRelease(key); CFRelease(val); CFRelease(dom);
}

static NSString *escaped(NSString *s) {
    if (!s) return [NSString string];
    NSMutableString *m = [NSMutableString stringWithString:s];
    [m replaceOccurrencesOfString:S("\\") withString:S("\\\\") options:0 range:NSMakeRange(0, [m length])];
    [m replaceOccurrencesOfString:S("\"") withString:S("\\\"") options:0 range:NSMakeRange(0, [m length])];
    [m replaceOccurrencesOfString:S("\n") withString:S(" ") options:0 range:NSMakeRange(0, [m length])];
    [m replaceOccurrencesOfString:S("\r") withString:S(" ") options:0 range:NSMakeRange(0, [m length])];
    return m;
}

static void do_request(const char *ctext) {
    NSString *urlStr = S(API_URL);
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) { setv("stage", "url-nil"); return; }
    setv("stage", "url-ok");

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    [req setHTTPMethod:S("POST")];
    [req setTimeoutInterval:30];
    [req setValue:S("application/json") forHTTPHeaderField:S("Content-Type")];
    NSString *auth = [S("Bearer ") stringByAppendingString:S(API_KEY)];
    [req setValue:auth forHTTPHeaderField:S("Authorization")];

    NSString *body = [NSString stringWithFormat:S("{\"model\":\"%s\",\"messages\":[{\"role\":\"user\",\"content\":\"%@\"}]}"),
                      API_MODEL, escaped(S(ctext))];
    [req setHTTPBody:[body dataUsingEncoding:NSUTF8StringEncoding]];
    setv("stage", "req-built");

    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            if (err) {
                char b[80];
                snprintf(b, sizeof b, "net-err %ld", (long)[err code]);
                setv("stage", b);
                return;
            }
            if (!data) { setv("stage", "no-data"); return; }
            id j = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
            NSString *content = nil;
            if ([j isKindOfClass:[NSDictionary class]]) {
                id ch = [j objectForKey:S("choices")];
                if ([ch isKindOfClass:[NSArray class]] && [ch count] > 0) {
                    id msg = [ch objectAtIndex:0];
                    if ([msg isKindOfClass:[NSDictionary class]]) {
                        id c = [msg objectForKey:S("message")];
                        if ([c isKindOfClass:[NSDictionary class]]) {
                            id t = [c objectForKey:S("content")];
                            if ([t isKindOfClass:[NSString class]]) content = t;
                        }
                    }
                }
            }
            if (content && [content length]) {
                setv("answer", [content UTF8String]);
                setv("stage", "answer-got");
            } else {
                setv("stage", "parse-fail");
            }
        }];
    [task resume];
    setv("stage", "task-resumed");
}

static IMP orig_speech = 0;
static long counter = 0;

static void my_speech(id self, SEL _cmd, id arg) {
    char text[2048];
    text[0] = 0;
    id best = ((id(*)(id, SEL))objc_msgSend)(arg, sel_registerName("af_bestTextInterpretation"));
    if (best) {
        const char *u = ((const char*(*)(id, SEL))objc_msgSend)(best, sel_registerName("UTF8String"));
        if (u) snprintf(text, sizeof text, "%s", u);
    }
    if (text[0]) {
        counter++;
        char nb[64];
        snprintf(nb, sizeof nb, "%ld-%ld", (long)time(0), counter);
        setv("text", text);
        setv("reqn", nb);
        setv("stage", "asking");
        char *copy = strdup(text);
        if (copy) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                do_request(copy);
                free(copy);
            });
        }
    } else {
        setv("text", "<nil>");
    }
    if (orig_speech) ((void(*)(id, SEL, id))orig_speech)(self, _cmd, arg);
}

static void *worker(void *a) {
    (void)a;
    sleep(3);
    id cls = objc_getClass("AFConnectionClientServiceDelegate");
    if (!cls) { setv("stage", "cls-null"); return 0; }
    Method m = class_getInstanceMethod(cls, sel_registerName("speechRecognized:"));
    if (!m) { setv("stage", "method-null"); return 0; }
    orig_speech = method_getImplementation(m);
    method_setImplementation(m, (IMP)my_speech);
    setv("stage", "hooked-nolit");
    return 0;
}

__attribute__((constructor)) static void siri_init(void) {
    pthread_t th;
    if (pthread_create(&th, 0, worker, 0) == 0) pthread_detach(th);
}
