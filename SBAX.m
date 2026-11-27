// SBAX.m — 1.6.40
// 用 AXUIElement（辅助功能通道）做跨进程"看控件 / 点控件"。
// 不注入目标 App，不需要 HID 投递 entitlement，不碰 backboardd。
// 走文件命令通道：/rootfs/private/var/mobile/Library/SiriBridge/cmd.txt（Shell 侧写）
//                /var/mobile/Library/SiriBridge/out.txt（SpringBoard 侧写，Shell 用 /rootfs 前缀读）

#import "SiriBridge.h"
#import <sys/sysctl.h>
#import <dlfcn.h>

typedef CFTypeRef AXEl;
typedef int AXErr;

static AXEl (*FApp)(int);
static AXErr (*FCopy)(AXEl, CFStringRef, CFTypeRef *);
static AXErr (*FAct)(AXEl, CFStringRef);
static AXErr (*FAt)(AXEl, float, float, AXEl *);
static int g_axState = 0;   // 0 未探测 / 1 可用 / -1 不可用

static CFStringRef AXK(const char *c) {
    return CFStringCreateWithCString(NULL, c, kCFStringEncodingUTF8);
}

static int SBAXReady(void) {
    if (g_axState) return g_axState > 0;
    g_axState = -1;
    void *h = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_NOW);
    if (!h) h = dlopen("/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities", RTLD_NOW);
    if (!h) h = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW);
    if (!h) h = RTLD_DEFAULT;
    FApp  = dlsym(h, "AXUIElementCreateApplication");
    FCopy = dlsym(h, "AXUIElementCopyAttributeValue");
    FAct  = dlsym(h, "AXUIElementPerformAction");
    FAt   = dlsym(h, "AXUIElementCopyElementAtPosition");
    if (!FApp || !FCopy) { SBLog("AX miss app=%d copy=%d h=%p", !!FApp, !!FCopy, h); return 0; }
    g_axState = 1;
    SBLog("AX ready act=%d at=%d h=%p", !!FAct, !!FAt, h);
    return 1;
}

// 按进程名找 pid（sysctl 全表，无需私有类）
static int SBPidOf(const char *nm) {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t sz = 0;
    if (sysctl(mib, 4, NULL, &sz, NULL, 0) != 0) return -1;
    struct kinfo_proc *kp = malloc(sz);
    if (!kp) return -1;
    if (sysctl(mib, 4, kp, &sz, NULL, 0) != 0) { free(kp); return -1; }
    int n = (int)(sz / sizeof(struct kinfo_proc)), r = -1;
    size_t ln = strlen(nm);
    for (int i = 0; i < n; i++) {
        const char *c = kp[i].kp_proc.p_comm;
        if (!c || !*c) continue;
        if (strncasecmp(c, nm, ln) == 0) { r = kp[i].kp_proc.p_pid; break; }
    }
    free(kp);
    return r;
}

static CFStringRef AXAttr(AXEl e, const char *a) {   // 调用方负责 CFRelease
    CFStringRef k = AXK(a);
    CFTypeRef v = NULL;
    AXErr r = FCopy(e, k, &v);
    CFRelease(k);
    if (r != 0 || !v) return NULL;
    if (CFGetTypeID(v) != CFStringGetTypeID()) { CFRelease(v); return NULL; }
    return (CFStringRef)v;
}

static void AXStrTo(char *dst, size_t cap, CFStringRef s) {
    dst[0] = 0;
    if (!s) return;
    CFStringGetCString(s, dst, cap, kCFStringEncodingUTF8);
}

static AXEl AXChild(AXEl e, int idx) {
    CFStringRef k = AXK("AXChildren");
    CFTypeRef v = NULL;
    AXEl r = NULL;
    if (FCopy(e, k, &v) == 0 && v && CFGetTypeID(v) == CFArrayGetTypeID()) {
        CFArrayRef a = (CFArrayRef)v;
        if (idx >= 0 && idx < CFArrayGetCount(a)) r = (AXEl)CFArrayGetValueAtIndex(a, idx);
        if (r) CFRetain(r);
    }
    if (v) CFRelease(v);
    CFRelease(k);
    return r;
}

static int AXChildCount(AXEl e) {
    CFStringRef k = AXK("AXChildren");
    CFTypeRef v = NULL;
    int n = 0;
    if (FCopy(e, k, &v) == 0 && v && CFGetTypeID(v) == CFArrayGetTypeID()) n = CFArrayGetCount((CFArrayRef)v);
    if (v) CFRelease(v);
    CFRelease(k);
    return n;
}

// ---------------- 输出缓冲 ----------------
typedef struct { char *b; size_t cap; size_t u; } Buf;
static void BApp(Buf *o, const char *fmt, ...) {
    if (o->u + 400 >= o->cap) return;
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(o->b + o->u, o->cap - o->u - 1, fmt, ap);
    va_end(ap);
    if (n > 0) o->u += (size_t)n;
}

// ---------------- dump / 查找 ----------------
static int g_walkBudget;
static int g_hit;

static void AXWalk(AXEl e, int depth, const char *kw, int press, Buf *o) {
    if (!e || depth > 6 || g_walkBudget <= 0) return;
    g_walkBudget--;

    CFStringRef role = AXAttr(e, "AXRole");
    CFStringRef title = AXAttr(e, "AXTitle");
    CFStringRef desc = AXAttr(e, "AXDescription");
    CFStringRef label = AXAttr(e, "AXLabel");
    CFStringRef val = AXAttr(e, "AXValue");
    CFStringRef ident = AXAttr(e, "AXIdentifier");

    char r[64], t[140], d[140], l[140], v[140], id[64];
    AXStrTo(r, sizeof r, role);
    AXStrTo(t, sizeof t, title);
    AXStrTo(d, sizeof d, desc);
    AXStrTo(l, sizeof l, label);
    AXStrTo(v, sizeof v, val);
    AXStrTo(id, sizeof id, ident);

    int match = 0;
    if (kw && *kw) {
        // 只在叶子语义字段里找，不做整行模糊，避免"256"这类误命中
        if ((t[0] && strstr(t, kw)) || (d[0] && strstr(d, kw)) || (l[0] && strstr(l, kw)) ||
            (v[0] && strstr(v, kw)) || (id[0] && strstr(id, kw))) match = 1;
    }

    BApp(o, "%*s%s|T=%s|D=%s|V=%s%s\n", depth * 2, "", r[0] ? r : "?", t, d, v,
         match ? "  <<HIT" : "");

    if (match) {
        g_hit++;
        if (press && FAct) {
            CFStringRef pk = AXK("AXPress");
            AXErr er = FAct(e, pk);
            CFRelease(pk);
            BApp(o, "%*sPRESS rc=%d\n", depth * 2 + 2, "", er);
        }
    }

    if (role) CFRelease(role);
    if (title) CFRelease(title);
    if (desc) CFRelease(desc);
    if (label) CFRelease(label);
    if (val) CFRelease(val);
    if (ident) CFRelease(ident);

    int n = AXChildCount(e);
    for (int i = 0; i < n && g_walkBudget > 0; i++) {
        AXEl c = AXChild(e, i);
        if (c) { AXWalk(c, depth + 1, kw, press, o); CFRelease(c); }
    }
}

static void SBAXRun(const char *line, Buf *o) {
    // 命令格式：
    //   pid <procname>
    //   ax <procname> [kw]        —— dump（带 kw 则标记命中）
    //   press <procname> <kw>     —— 找第一个命中并 AXPress
    char a[64] = {0}, b[128] = {0}, c[128] = {0};
    sscanf(line, "%63s %127s %127s", a, b, c);

    if (strcmp(a, "pid") == 0) {
        int p = SBPidOf(b);
        BApp(o, "pid(%s)=%d\n", b, p);
        return;
    }

    if (!SBAXReady()) { BApp(o, "AX not ready\n"); return; }

    int pid = SBPidOf(b);
    BApp(o, "target=%s pid=%d\n", b, pid);
    if (pid <= 0) return;

    AXEl app = FApp(pid);
    if (!app) { BApp(o, "AXUIElementCreateApplication null\n"); return; }

    CFStringRef kwk = AXK("AXWindows");
    CFTypeRef wins = NULL;
    AXErr r = FCopy(app, kwk, &wins);
    CFRelease(kwk);
    BApp(o, "windows rc=%d type=%d\n", r, wins ? (int)CFGetTypeID(wins) : 0);

    if (wins && CFGetTypeID(wins) == CFArrayGetTypeID()) {
        CFArrayRef wa = (CFArrayRef)wins;
        int wn = CFArrayGetCount(wa);
        BApp(o, "window count=%d\n", wn);
        g_walkBudget = 400;
        g_hit = 0;
        int doPress = (strcmp(a, "press") == 0);
        const char *kw = (strcmp(a, "pid") == 0) ? NULL : (c[0] ? c : (b[0] ? NULL : NULL));
        if (strcmp(a, "press") == 0) kw = c;
        else if (strcmp(a, "ax") == 0) kw = c;
        for (int i = 0; i < wn; i++) {
            AXEl w = (AXEl)CFArrayGetValueAtIndex(wa, i);
            BApp(o, "--win %d\n", i);
            AXWalk(w, 0, kw, doPress, o);
        }
        BApp(o, "done hit=%d budget=%d\n", g_hit, g_walkBudget);
    }
    if (wins) CFRelease(wins);
    CFRelease(app);
}

// ---------------- 文件命令通道 ----------------
#define SB_CMD_PATH SB_HOME_DIR "/cmd.txt"
#define SB_OUT_PATH SB_HOME_DIR "/out.txt"

static void sbCmdOnce(void) {
    FILE *f = fopen(SB_CMD_PATH, "r");
    if (!f) return;
    char line[512] = {0};
    size_t n = fread(line, 1, sizeof line - 1, f);
    fclose(f);
    while (n && (line[n-1] == '\n' || line[n-1] == '\r' || line[n-1] == ' ' || line[n-1] == '\t')) line[--n] = 0;
    if (!n) { unlink(SB_CMD_PATH); return; }
    unlink(SB_CMD_PATH);                     // 先删，保证只执行一次

    SBLog("CMD %s", line);

    char *ob = malloc(4096);
    if (!ob) return;
    Buf o = { ob, 4096, 0 };
    ob[0] = 0;
    SBAXRun(line, &o);
    ob[o.u < 4096 ? o.u : 4095] = 0;

    char tmp[440];
    snprintf(tmp, sizeof tmp, "%s.tmp", SB_OUT_PATH);
    FILE *g = fopen(tmp, "w");
    if (g) { fwrite(ob, 1, strlen(ob), g); fclose(g); rename(tmp, SB_OUT_PATH); }
    else SBLog("CMD out write fail errno=%d", errno);
    free(ob);
}

static void *sbCmdThread(void *a) {
    (void)a;
    usleep(800000);
    for (;;) {
        sbCmdOnce();
        usleep(1200000);                     // 1.2s 轮询，开销可忽略
    }
    return NULL;
}

void SBAXCmdBoot(void) {
    pthread_t th;
    if (pthread_create(&th, NULL, sbCmdThread, NULL) == 0) pthread_detach(th);
    else SBLog("AX cmd thread fail");
}
