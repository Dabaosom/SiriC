#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <pthread.h>
#include <unistd.h>

#define PREFDOMAIN "com.doubao.siriaigh"

static void setv(const char *k, const char *v) {
    if (!v) v = "";
    CFStringRef key = CFStringCreateWithCString(0, k, kCFStringEncodingUTF8);
    CFStringRef val = CFStringCreateWithCString(0, v, kCFStringEncodingUTF8);
    CFStringRef dom = CFStringCreateWithCString(0, PREFDOMAIN, kCFStringEncodingUTF8);
    CFPreferencesSetAppValue(key, val, dom);
    CFPreferencesAppSynchronize(dom);
    CFRelease(key); CFRelease(val); CFRelease(dom);
}

/* 只探针，不联网、不 hook 任何东西 */
static void *worker(void *a) {
    (void)a;
    sleep(3);

    setv("probeStage", "A-run");
    @autoreleasepool {
        const char *u = "https://example.com";
        NSString *s = [[NSString alloc] initWithUTF8String:u];
        setv("probeStage", "A-has-str");
        NSURL *url = [NSURL URLWithString:s];
        setv("probeRun", url ? "ok" : "nil");
    }
    setv("probeStage", "A-done");

    sleep(2);

    setv("probeStage", "B-lit");
    @autoreleasepool {
        NSURL *url2 = [NSURL URLWithString:@"https://example.com"];
        setv("probeLit", url2 ? "ok" : "nil");
    }
    setv("probeStage", "B-done");
    return 0;
}

__attribute__((constructor)) static void probe_init(void) {
    pthread_t th;
    if (pthread_create(&th, 0, worker, 0) == 0) pthread_detach(th);
}
