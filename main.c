#include <CoreFoundation/CoreFoundation.h>
#include <objc/runtime.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <time.h>
#include <stdio.h>
#include <sys/socket.h>
#include <netinet/in.h>

/* 只验证 SpringBoard 能不能连本机回环端口，不做别的 */
static void setv(const char *k, const char *v);
static void tcp_probe(void) {
    char res[256];
    res[0] = 0;
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) { setv("tcp", "socket-fail"); return; }
    struct sockaddr_in a;
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_port = htons(9999);
    a.sin_addr.s_addr = htonl(0x7f000001);
    if (connect(s, (struct sockaddr *)&a, sizeof a) < 0) {
        close(s);
        setv("tcp", "connect-fail");
        return;
    }
    if (write(s, "ping", 4) < 0) {
        close(s);
        setv("tcp", "write-fail");
        return;
    }
    char r[1024];
    int n = (int)read(s, r, sizeof r - 1);
    close(s);
    if (n <= 0) { setv("tcp", "read-fail"); return; }
    r[n] = 0;
    for (int i = 0; i < n; i++) if (r[i] == '\n' || r[i] == '\r') r[i] = ' ';
    snprintf(res, sizeof res, "ok %s", r);
    setv("tcp", res);
}

#define PREFDOMAIN "com.doubao.siriaigh"
#define RESDOMAIN  "com.doubao.siricres"

static void setv(const char *k, const char *v) {
    if (!v) v = "";
    CFStringRef key = CFStringCreateWithCString(0, k, 0x08000100);
    CFStringRef val = CFStringCreateWithCString(0, v, 0x08000100);
    CFStringRef dom = CFStringCreateWithCString(0, PREFDOMAIN, 0x08000100);
    CFPreferencesSetAppValue(key, val, dom);
    CFPreferencesAppSynchronize(dom);
    CFRelease(key); CFRelease(val); CFRelease(dom);
}

/* 直读 /Library/Preferences 下的纯文本（不做任何 CFPreferences 调用，避免阻塞） */
static int readf(const char *p, char *buf, int max) {
    FILE *f = fopen(p, "r");
    if (!f) return -1;
    int n = (int)fread(buf, 1, max - 1, f);
    fclose(f);
    if (n < 0) n = 0;
    buf[n] = 0;
    while (n > 0 && (buf[n-1] == '\n' || buf[n-1] == '\r' || buf[n-1] == ' ')) buf[--n] = 0;
    return n;
}

static void *(*f_objc_getClass)(const char *) = 0;
static SEL (*f_sel_registerName)(const char *) = 0;
static Method (*f_class_getInstanceMethod)(void *, SEL) = 0;
static IMP (*f_method_getImplementation)(Method) = 0;
static IMP (*f_method_setImplementation)(Method, IMP) = 0;
static id (*f_msgSend)(id, SEL, ...) = 0;

static IMP orig_speech = 0;
static long counter = 0;

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
        counter++;
        char nb[64];
        snprintf(nb, sizeof nb, "%ld-%ld", (long)time(0), counter);
        setv("text", text);
        setv("req", text);
        setv("reqn", nb);
        setv("stage", "asked");

        char probe[64]; probe[0] = 0;
        readf("/Library/Preferences/siric_ansn.txt", probe, sizeof probe);
        setv("libread", probe[0] ? probe : "<none>");

        for (int i = 0; i < 60; i++) {
            usleep(200000);
            char an[64]; an[0] = 0;
            if (readf("/Library/Preferences/siric_ansn.txt", an, sizeof an) > 0 && strcmp(an, nb) == 0) {
                char ans[4096]; ans[0] = 0;
                if (readf("/Library/Preferences/siric_ans.txt", ans, sizeof ans) > 0)
                    setv("answer", ans);
                setv("stage", ans[0] ? "answer-got" : "answer-empty");
                break;
            }
        }
        char seen[64]; seen[0] = 0;
        readf("/Library/Preferences/siric_ansn.txt", seen, sizeof seen);
        setv("ansn-seen", seen);
    } else {
        setv("text", "<nil>");
    }
    if (orig_speech) ((void(*)(id, SEL, id))orig_speech)(self, _cmd, arg);
}

static void *worker(void *a) {
    (void)a;
    sleep(3);
    tcp_probe();
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
    pthread_t th;
    if (pthread_create(&th, 0, worker, 0) == 0) pthread_detach(th);
}
