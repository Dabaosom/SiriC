#import "SiriBridge.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <time.h>

#pragma mark - 日志（单进程单写者，写自己容器）

void SBLogLine(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    static pthread_mutex_t mtx = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&mtx);
    const char *home = getenv("HOME");
    char path[600];
    snprintf(path, sizeof path, "%s/Library/Caches/siribridge.log", home ? home : "/tmp");
    FILE *f = fopen(path, "a");
    if (f) {
        fprintf(f, "%ld %s\n", (long)time(NULL), msg.UTF8String ?: "");
        fclose(f);
    }
    pthread_mutex_unlock(&mtx);
    [msg release];
}

#pragma mark - 运行时工具

BOOL SBHasClass(NSString *name) {
    return objc_getClass(name.UTF8String) != Nil;
}

BOOL SBHasSel(id obj, NSString *selName) {
    if (!obj || !selName.length) return NO;
    return [obj respondsToSelector:sel_registerName(selName.UTF8String)];
}

BOOL SBSet(id obj, NSString *selName, id value) {
    if (!obj || !value || !SBHasSel(obj, selName)) return NO;
    ((void (*)(id, SEL, id))objc_msgSend)(obj, sel_registerName(selName.UTF8String), value);
    return YES;
}

id SBNew(NSString *className) {
    Class c = objc_getClass(className.UTF8String);
    if (!c) return nil;
    id o = ((id (*)(id, SEL))objc_msgSend)((id)c, sel_registerName("alloc"));
    if (!o) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(o, sel_registerName("init"));
}

NSString *SBUUID(void) {
    return [[[NSUUID UUID] UUIDString] lowercaseString];
}

#pragma mark - 主链路（C 函数指针，不持有 block）

static SBTextFn g_textFn = NULL;
static BOOL g_busy = NO;
static int g_gen = 0;

typedef struct { id conn; int gen; } SBJob;

#if SB_STAGE >= 2
static void SBOnAnswer(void *ctx, NSString *answer, NSString *err);

static void SBRequest(NSString *text, id conn) {
    if (g_busy) { SBLog(@"REQ busy drop"); return; }
    SBJob *job = calloc(1, sizeof(SBJob));
    if (!job) { SBLog(@"REQ no mem"); return; }
    job->conn = [(id)conn retain];
    job->gen = ++g_gen;
    g_busy = YES;
    SBLog(@"REQ start gen=%d len=%lu", job->gen, (unsigned long)text.length);
    SBNetPost(text, SBOnAnswer, job);
}

static void SBOnAnswer(void *ctx, NSString *answer, NSString *err) {
    SBJob *job = (SBJob *)ctx;
    dispatch_async(dispatch_get_main_queue(), ^{
        g_busy = NO;
        if (job->gen != g_gen) SBLog(@"RES stale gen=%d now=%d", job->gen, g_gen);
        if (!answer.length) {
            SBLog(@"RES fail %@", err ?: @"?");
            [job->conn release];
            free(job);
            return;
        }
        SBLog(@"RES answer len=%lu", (unsigned long)answer.length);
#if SB_STAGE >= 3
        id cmd = SBAceAddViews(answer);
        if (cmd) [SBSubmitter submit:cmd on:job->conn];
#if SB_STAGE >= 4
        id tts = SBAcePreSynthTTS(answer);
        if (tts) [SBSubmitter submit:tts on:job->conn];
#endif
#endif
        [job->conn release];
        free(job);
    });
}
#endif

static void SBOnText(NSString *text, id conn) {
    SBLog(@"TEXT len=%lu", (unsigned long)text.length);
#if SB_STAGE >= 1
    if (!text.length) return;
    if (SBRouteNative(text)) return;
#if SB_STAGE >= 2
    if (!conn) { SBLog(@"TEXT no conn, cannot submit later"); }
    SBRequest(text, conn);
#endif
#endif
}

#pragma mark - 能力探测

static void SBProbe(void) {
    NSArray *classes = @[ @"AFConnection", @"AFConnectionClientServiceDelegate",
                          @"SAUIAddViews", @"SAUIAssistantUtteranceView", @"SAPreSynthesizeTTS" ];
    for (NSString *n in classes) SBLog(@"PROBE class %@=%d", n, (int)SBHasClass(n));

    Class conn = objc_getClass("AFConnection");
    if (conn) {
        NSArray *sels = @[ @"_tellSpeechDelegateSpeechRecognized:", @"_handleCommand:reply:",
                           @"startRequestWithText:", @"speechRecognized:" ];
        for (NSString *s in sels) {
            Method m = class_getInstanceMethod(conn, sel_registerName(s.UTF8String));
            SBLog(@"PROBE sel %@=%d", s, m ? 1 : 0);
        }
    }
}

#pragma mark - 启动

__attribute__((constructor))
static void SBBoot(void) {
    SBLog(@"BOOT stage=%d pid=%d", SB_STAGE,
          (int)[[NSProcessInfo processInfo] processIdentifier]);
    SBProbe();

    Class conn = objc_getClass("AFConnection");
    Class del = objc_getClass("AFConnectionClientServiceDelegate");
    if (!conn && !del) { SBLog(@"BOOT no AF classes"); return; }

#if SB_STAGE >= 3
    BOOL sub = [SBSubmitter install];
    SBLog(@"BOOT submit=%d", (int)sub);
#endif
    BOOL recog = SBInstallRecognitionHook(conn, del);
    SBLog(@"BOOT recog=%d", (int)recog);
    if (recog) SBSetTextFunc(SBOnText);
}
