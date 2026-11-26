#import "SiriBridge.h"
#include <stdio.h>
#include <objc/runtime.h>
#include <pthread.h>
#include <sys/stat.h>
#include <unistd.h>

//  只读探针：把 AFConnection 等类的方法名清单写到文件，供本地分析。
//  不做任何 hook、不发任何消息，崩溃风险为零。

static const char *kProbeClasses[] = {
    "AFConnection",
    "AFConnectionManager",
    "AFConnectionClientServiceDelegate",
    "SiriUISiriSession",
    "SASUpdateViewsCommand",
    "SAAceCommand",
    NULL
};

static void sbDumpOne(FILE *f, const char *clsName) {
    Class c = objc_getClass(clsName);
    if (!c) { fprintf(f, "== %s MISSING\n", clsName); return; }
    fprintf(f, "== %s super=%s\n", clsName, class_getName(class_getSuperclass(c)));
    unsigned int n = 0;
    Method *ms = class_copyMethodList(c, &n);
    if (!ms) { fprintf(f, "   (none)\n"); return; }
    fprintf(f, "   count=%u\n", n);
    for (unsigned int i = 0; i < n; i++) {
        const char *sn = sel_getName(method_getName(ms[i]));
        const char *ty = method_getTypeEncoding(ms[i]);
        fprintf(f, "   %s | %s\n", sn, ty ? ty : "?");
    }
    free(ms);
}

static void *sbDumpThread(void *a) {
    (void)a;
    sleep(6);
    FILE *f = fopen("/var/mobile/Documents/aiassist/methods.txt", "w");
    if (!f) { SBLogSync("DUMP nofile"); return NULL; }
    fprintf(f, "begin\n");
    for (int i = 0; kProbeClasses[i]; i++) sbDumpOne(f, kProbeClasses[i]);
    fprintf(f, "end\n");
    fclose(f);
    chmod("/var/mobile/Documents/aiassist/methods.txt", 0644);
    SBLogSync("DUMP done");
    return NULL;
}

void SBProbeDump(void) {
    pthread_t th;
    if (pthread_create(&th, NULL, sbDumpThread, NULL) == 0) pthread_detach(th);
}
