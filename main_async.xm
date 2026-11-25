#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <pthread.h>
#import <unistd.h>
#include <time.h>

#define PREFDOMAIN "com.doubao.siriaigh"
#define API_URL "https://apihub.agnes-ai.com/v1/chat/completions"
#define API_KEY "sk-V0QgHosRfr9EIMgHG6SdQX60z5zVq3JXG0zJ4uNfsPxdsmis"
#define API_MODEL "agnes-3.0-flash"

static void setv(const char *k, const char *v) {
    if (!v) v = "";
    CFStringRef key = CFStringCreateWithCString(0, k, kCFStringEncodingUTF8);
    CFStringRef val = CFStringCreateWithCString(0, v, kCFStringEncodingUTF8);
    CFStringRef dom = CFStringCreateWithCString(0, PREFDOMAIN, kCFStringEncodingUTF8);
    CFPreferencesSetAppValue(key, val, dom);
    CFPreferencesAppSynchronize(dom);
    CFRelease(key); CFRelease(val); CFRelease(dom);
}

static NSString *escapeJSON(NSString *s) {
    NSMutableString *m = [NSMutableString stringWithString:s ?: @""];
    [m replaceOccurrencesOfString:@"\\" withString:@"\\\\" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"\"" withString:@"\\\"" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"\n" withString:@" " options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"\r" withString:@" " options:0 range:NSMakeRange(0, m.length)];
    return m;
}

/* 全异步：不阻塞任何线程，结果只写偏好域 */
static void request_async(NSString *text) {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@API_URL]];
    [req setHTTPMethod:@"POST"];
    [req setTimeoutInterval:30];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer %s", API_KEY] forHTTPHeaderField:@"Authorization"];
    NSString *body = [NSString stringWithFormat:@"{\"model\":\"%s\",\"messages\":[{\"role\":\"user\",\"content\":\"%@\"}]}",
                      API_MODEL, escapeJSON(text)];
    [req setHTTPBody:[body dataUsingEncoding:NSUTF8StringEncoding]];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            if (err) {
                setv("stage", [[NSString stringWithFormat:@"net-err %ld", (long)err.code] UTF8String]);
                return;
            }
            if (!data) { setv("stage", "no-data"); return; }
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSString *content = nil;
            if ([json isKindOfClass:[NSDictionary class]]) {
                id ch = json[@"choices"];
                if ([ch isKindOfClass:[NSArray class]] && [ch count]) {
                    id msg = ch[0][@"message"];
                    if ([msg isKindOfClass:[NSDictionary class]]) content = msg[@"content"];
                }
            }
            if ([content isKindOfClass:[NSString class]] && content.length) {
                setv("answer", [content UTF8String]);
                setv("stage", "answer-got");
            } else {
                setv("stage", "parse-fail");
                setv("raw", [[data description] UTF8String]);
            }
        }];
    [task resume];
}

static IMP orig_speech = 0;
static long counter = 0;

static void my_speech(id self, SEL _cmd, id arg) {
    char text[2048];
    text[0] = 0;
    @autoreleasepool {
        id best = ((id(*)(id, SEL))objc_msgSend)(arg, sel_registerName("af_bestTextInterpretation"));
        if (best) {
            const char *u = ((const char*(*)(id, SEL))objc_msgSend)(best, sel_registerName("UTF8String"));
            if (u && u[0]) snprintf(text, sizeof text, "%s", u);
            if (!text[0]) {
                const char *d = ((const char*(*)(id, SEL))objc_msgSend)(best, sel_registerName("description"));
                if (d) snprintf(text, sizeof text, "%s", d);
            }
        }
        if (text[0]) {
            counter++;
            char nb[64];
            snprintf(nb, sizeof nb, "%ld-%ld", (long)time(0), counter);
            setv("text", text);
            setv("reqn", nb);
            setv("stage", "requesting");
            NSString *t = [NSString stringWithUTF8String:text];
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                @autoreleasepool { request_async(t); }
            });
        } else {
            setv("text", "<nil>");
        }
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
    setv("stage", "hooked-async");
    return 0;
}

__attribute__((constructor)) static void siri_init(void) {
    pthread_t th;
    if (pthread_create(&th, 0, worker, 0) == 0) pthread_detach(th);
}
