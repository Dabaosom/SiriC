#include <CoreFoundation/CoreFoundation.h>
#include <objc/runtime.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <time.h>
#include <stdio.h>
#include <sys/stat.h>

#define PREFDOMAIN  "com.doubao.siriaigh"
#define REQFILE "/var/mobile/Library/Caches/siric_req.txt"
#define REQN_F  "/var/mobile/Library/Caches/siric_reqn.txt"
#define ANSFILE "/var/mobile/Library/Caches/siric_ans.txt"
#define ANSN_F  "/var/mobile/Library/Caches/siric_ansn.txt"

typedef id (*msgSendId)(id, SEL);
typedef id (*msgSendStr)(id, SEL, char *);
typedef void (*msgSendVoidImp)(id, SEL, id);

static void setv(const char *k, const char *v) {
    if (!v) v = "";
    CFStringRef key = CFStringCreateWithCString(0, k, 0x08000100);
    CFStringRef val = CFStringCreateWithCString(0, v, 0x08000100);
    CFStringRef dom = CFStringCreateWithCString(0, PREFDOMAIN, 0x08000100);
    CFPreferencesSetAppValue(key, val, dom);
    CFPreferencesAppSynchronize(dom);
    CFRelease(key); CFRelease(val); CFRelease(dom);
}

static int writefile(const char *p, const char *s) {
    FILE *f = fopen(p, "w");
    if (!f) return 0;
    fputs(s, f);
    fclose(f);
    return 1;
}

static int readfile(const char *p, char *buf, int max) {
    FILE *f = fopen(p, "r");
    if (!f) return -1;
    int n = (int)fread(buf, 1, max - 1, f);
    fclose(f);
    if (n < 0) n = 0;
    buf[n] = 0;
    while (n > 0 && (buf[n-1] == '\n' || buf[n-1] == '\r' || buf[n-1] == ' ')) buf[--n] = 0;
    return n;
}

static long counter = 0;
static char tstamp[32];

static void makeStamp(void) {
    long t = (long)time(0);
    snprintf(tstamp, sizeof tstamp, "%ld", t);
}

/* --- objc runtime handles --- */
static void *(*f_objc_getClass)(const char *) = 0;
static SEL (*f_sel_registerName)(const char *) = 0;
static Method (*f_class_getInstanceMethod)(void *, SEL) = 0;
static IMP (*f_method_getImplementation)(Method) = 0;
static IMP (*f_method_setImplementation)(Method, IMP) = 0;
static id (*f_msgSend)(id, SEL, ...) = 0;

static IMP orig_speech = 0;

static void my_speech(id self, SEL _cmd, id arg) {
    char text[2048];
    text[0] = 0;
    if (f_msgSend) {
        SEL selBest = f_sel_registerName("af_bestTextInterpretation");
        SEL selUTF = f_sel_registerName("UTF8String");
        id best = ((id(*)(id, SEL))f_msgSend)(arg, selBest);
        if (best) {
            const char *s = ((const char*(*)(id, SEL))f_msgSend)(best, selUTF);
            if (s) snprintf(text, sizeof text, "%s", s);
        }
    }
    if (text[0]) {
        setv("text", text);
        counter++;
        char nb[64];
        snprintf(nb, sizeof nb, "%ld-%ld", (long)time(0), counter);

        char *dirs[] = {
            "/var/mobile/Library/Caches/",
            "/var/mobile/Library/Preferences/",
            "/var/mobile/tmp/",
            "/var/mobile/Documents/",
            "/var/mobile/Library/SiricHub/",
            0
        };
        char dir[256]; dir[0] = 0;
        for (int i = 0; dirs[i]; i++) {
            char p[256];
            snprintf(p, sizeof p, "%ssiric_new.txt", dirs[i]);
            if (writefile(p, nb)) { snprintf(dir, sizeof dir, "%s", dirs[i]); break; }
        }
        if (dir[0]) setv("wpath", dir); else setv("wpath", "<none>");

        if (dir[0]) {
            char p[256];
            snprintf(p, sizeof p, "%ssiric_req.txt", dir);
            writefile(p, text);
            snprintf(p, sizeof p, "%ssiric_reqn.txt", dir);
            writefile(p, nb);
        }
        setv("reqn", nb);
        setv("stage", "asked");

        for (int i = 0; i < 75; i++) {
            if (!dir[0]) break;
            usleep(200000);
            char p[256], an[64];
            snprintf(p, sizeof p, "%ssiric_ansn.txt", dir);
            an[0] = 0;
            if (readfile(p, an, sizeof an) > 0 && strcmp(an, nb) == 0) {
                char ans[4096]; ans[0] = 0;
                snprintf(p, sizeof p, "%ssiric_ans.txt", dir);
                if (readfile(p, ans, sizeof ans) > 0) {
                    setv("answer", ans);
                    setv("stage", "answer-got");
                } else {
                    setv("stage", "answer-empty");
                }
                break;
            }
        }
    } else {
        setv("text", "<nil>");
    }
    if (orig_speech) ((void(*)(id, SEL, id))orig_speech)(self, _cmd, arg);
}

static void *worker(void *arg) {
    (void)arg;
    sleep(3);
    f_objc_getClass = dlsym(RTLD_DEFAULT, "objc_getClass");
    f_sel_registerName = dlsym(RTLD_DEFAULT, "sel_registerName");
    f_class_getInstanceMethod = dlsym(RTLD_DEFAULT, "class_getInstanceMethod");
    f_method_getImplementation = dlsym(RTLD_DEFAULT, "method_getImplementation");
    f_method_setImplementation = dlsym(RTLD_DEFAULT, "method_setImplementation");
    f_msgSend = dlsym(RTLD_DEFAULT, "objc_msgSend");
    if (!f_objc_getClass || !f_msgSend) { setv("stage", "dlsym-fail"); return 0; }
    id cls = f_objc_getClass("AFConnectionClientServiceDelegate");
    if (!cls) { setv("stage", "cls-null"); return 0; }
    SEL sel = f_sel_registerName("speechRecognized:");
    Method m = f_class_getInstanceMethod(cls, sel);
    if (!m) { setv("stage", "method-null"); return 0; }
    orig_speech = f_method_getImplementation(m);
    f_method_setImplementation(m, (IMP)my_speech);
    setv("stage", "hooked");
    return 0;
}

__attribute__((constructor)) static void siri_init(void) {
    /* 绝不在 dyld 初始化期碰 CF/objc：只起线程，睡 3 秒后再挂 */
    pthread_t th;
    if (pthread_create(&th, 0, worker, 0) == 0) pthread_detach(th);
}

