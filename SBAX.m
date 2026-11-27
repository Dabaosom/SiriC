// SBAX.m — 1.6.40
// 用 AXUIElement（辅助功能通道）做跨进程"看控件 / 点控件"。
// 不注入目标 App，不需要 HID 投递 entitlement，不碰 backboardd。
// 走文件命令通道：/rootfs/private/var/mobile/Library/SiriBridge/cmd.txt（Shell 侧写）
//                /var/mobile/Library/SiriBridge/out.txt（SpringBoard 侧写，Shell 用 /rootfs 前缀读）

#import "SiriBridge.h"
#import <sys/sysctl.h>
#import <dlfcn.h>
#import <pthread.h>
#import <string.h>
#import <errno.h>
#import <unistd.h>

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
    static const char *paths[] = {
        "/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime",
        "/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities",
        "/System/Library/PrivateFrameworks/Accessibility.framework/Accessibility",
        "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
        "/usr/lib/libAccessibility.dylib",
        NULL
    };
    void *hit = NULL;
    for (int i = 0; paths[i]; i++) {
        void *h = dlopen(paths[i], RTLD_NOW);
        SBLog("AX dl %d h=%p %s", i, h, paths[i]);
        if (h) {
            void *f = dlsym(h, "AXUIElementCreateApplication");
            if (f) { hit = h; FApp = (AXEl (*)(int))f; break; }
        }
    }
    if (!FApp) {
        void *f = dlsym(RTLD_DEFAULT, "AXUIElementCreateApplication");
        if (f) { hit = RTLD_DEFAULT; FApp = (AXEl (*)(int))f; }
    }
    if (!FApp) { SBLog("AX miss createApplication"); return 0; }
    FCopy = (AXErr (*)(AXEl, CFStringRef, CFTypeRef *))dlsym(hit, "AXUIElementCopyAttributeValue");
    FAct  = (AXErr (*)(AXEl, CFStringRef))dlsym(hit, "AXUIElementPerformAction");
    FAt   = (AXErr (*)(AXEl, float, float, AXEl *))dlsym(hit, "AXUIElementCopyElementAtPosition");
    if (!FCopy) { SBLog("AX miss copyAttribute"); return 0; }
    g_axState = 1;
    SBLog("AX ready act=%d at=%d", !!FAct, !!FAt);
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

// ---------------- 符号/类探测（诊断用） ----------------
#import <objc/runtime.h>
#import <objc/message.h>

#define MSG_ID ((id (*)(id, SEL))objc_msgSend)
#define MSG_INT ((int (*)(id, SEL))objc_msgSend)

static int axHas(id el, SEL s);

static void ax2Walk(id el, int depth, Buf *o, int *budget) {
    if (!el || depth > 3 || *budget <= 0) return;
    (*budget)--;
    NSString *bid = axHas(el, @selector(bundleId)) ? MSG_ID(el, @selector(bundleId)) : nil;
    id val = axHas(el, @selector(value)) ? MSG_ID(el, @selector(value)) : nil;
    int p = axHas(el, @selector(pid)) ? MSG_INT(el, @selector(pid)) : -1;
    id kids = axHas(el, @selector(children)) ? MSG_ID(el, @selector(children)) : nil;

    char vs[100] = {0};
    if (val) {
        CFTypeRef v = (CFTypeRef)val;
        CFTypeID t = CFGetTypeID(v);
        if (t == CFStringGetTypeID()) {
            CFStringGetCString((CFStringRef)v, vs, sizeof vs, kCFStringEncodingUTF8);
        } else if (t == CFNumberGetTypeID()) {
            snprintf(vs, sizeof vs, "num");
        } else {
            snprintf(vs, sizeof vs, "t%lu", (unsigned long)t);
        }
    }
    unsigned long kn = 0;
    if (kids && CFGetTypeID((CFTypeRef)kids) == CFArrayGetTypeID())
        kn = CFArrayGetCount((CFArrayRef)kids);

    BApp(o, "%*s d%d pid=%d bid=%s val=%s kids=%lu\n", depth * 2, "", depth, p,
         bid ? [bid UTF8String] : "-", vs, kn);

    if (kn && kn < 60 && kids) {
        CFArrayRef a = (CFArrayRef)kids;
        for (unsigned long i = 0; i < kn; i++) {
            CFTypeRef k = CFArrayGetValueAtIndex(a, (CFIndex)i);
            if (k) ax2Walk((id)k, depth + 1, o, budget);
        }
    }
}

static void AX2Run(const char *wantBundle, const char *kw, int press, Buf *o) {
    Class c = objc_getClass("AXElement");
    if (!c) { BApp(o, "no AXElement\n"); return; }
    id roots[3] = {NULL, NULL, NULL};
    const char *tags[3] = {"systemWide", "systemApplication", "systemEventDispatch"};
    if (class_respondsToSelector(c, @selector(systemWideElement)))
        roots[0] = MSG_ID((id)c, @selector(systemWideElement));
    if (class_respondsToSelector(c, @selector(systemApplication)))
        roots[1] = MSG_ID((id)c, @selector(systemApplication));
    if (class_respondsToSelector(c, @selector(systemEventDispatchElement)))
        roots[2] = MSG_ID((id)c, @selector(systemEventDispatchElement));
    for (int r = 0; r < 3; r++) {
        id root = roots[r];
        if (!root) { BApp(o, "%s=null\n", tags[r]); continue; }
        id apps = axHas(root, @selector(children)) ? MSG_ID(root, @selector(children)) : nil;
        unsigned long an = 0;
        if (apps && CFGetTypeID((CFTypeRef)apps) == CFArrayGetTypeID())
            an = CFArrayGetCount((CFArrayRef)apps);
        BApp(o, "%s=%p children=%lu\n", tags[r], root, an);
        if (!apps || !an) continue;
        CFArrayRef aa = (CFArrayRef)apps;
        for (unsigned long i = 0; i < an && i < 40; i++) {
            id a = (id)CFArrayGetValueAtIndex(aa, (CFIndex)i);
            NSString *bid = a && axHas(a, @selector(bundleId)) ? MSG_ID(a, @selector(bundleId)) : nil;
            int p = a && axHas(a, @selector(pid)) ? MSG_INT(a, @selector(pid)) : -1;
            BApp(o, " - [%lu] pid=%d bid=%s\n", i, p, bid ? [bid UTF8String] : "-");
            if (wantBundle && *wantBundle && bid &&
                [bid isEqualToString:[NSString stringWithUTF8String:wantBundle]]) {
                BApp(o, "   >>> MATCH\n");
                int budget = 70;
                ax2Walk(a, 0, o, &budget);
                BApp(o, "   >>> left=%d\n", budget);
            }
        }
    }
}

static int axHas(id el, SEL s) {
    Class k = object_getClass(el);
    return k && class_respondsToSelector(k, s);
}

static void axDesc(id el, Buf *o, const char *tag, int depth) {
    if (!el) { BApp(o, "%s el=nil\n", tag); return; }
    NSString *bid = axHas(el, @selector(bundleId)) ? MSG_ID(el, @selector(bundleId)) : nil;
    id val = axHas(el, @selector(value)) ? MSG_ID(el, @selector(value)) : nil;
    int p = axHas(el, @selector(pid)) ? MSG_INT(el, @selector(pid)) : -1;
    id kids = axHas(el, @selector(children)) ? MSG_ID(el, @selector(children)) : nil;
    CGRect fr;
    fr.origin.x = 0; fr.origin.y = 0; fr.size.width = 0; fr.size.height = 0;
    if (axHas(el, @selector(frame))) fr = ((CGRect (*)(id, SEL))objc_msgSend)(el, @selector(frame));
    char vs[110] = {0};
    if (val) {
        CFTypeID t = CFGetTypeID((CFTypeRef)val);
        if (t == CFStringGetTypeID()) CFStringGetCString((CFStringRef)val, vs, sizeof vs, kCFStringEncodingUTF8);
        else snprintf(vs, sizeof vs, "t%lu", (unsigned long)t);
    }
    unsigned long kn = 0;
    if (kids && CFGetTypeID((CFTypeRef)kids) == CFArrayGetTypeID()) kn = CFArrayGetCount((CFArrayRef)kids);
    BApp(o, "%s el=%p pid=%d bid=%s val=%s kids=%lu frame=%.0f,%.0f,%.0f,%.0f\n",
         tag, el, p, bid ? [bid UTF8String] : "-", vs, kn, fr.origin.x, fr.origin.y, fr.size.width, fr.size.height);
    if (kn && kn < 40 && depth < 1) {
        CFArrayRef a = (CFArrayRef)kids;
        for (unsigned long i = 0; i < kn && i < 8; i++) {
            id k = (id)CFArrayGetValueAtIndex(a, (CFIndex)i);
            axDesc(k, o, "   child", depth + 1);
        }
    }
}

static void AXAtRun(double x, double y, int press, Buf *o) {
    CGPoint pt;
    pt.x = x;
    pt.y = y;
    id el = NULL;
    Class c1 = objc_getClass("AXElement");
    Class c2 = objc_getClass("AXUIElement");

    if (c1 && class_respondsToSelector(c1, @selector(elementAtCoordinate:withVisualPadding:))) {
        el = ((id (*)(id, SEL, CGPoint, char))objc_msgSend)((id)c1,
             @selector(elementAtCoordinate:withVisualPadding:), pt, (char)0);
        BApp(o, "AXElement elementAtCoordinate:withVisualPadding: -> %p\n", el);
    }
    if (!el && c1 && class_respondsToSelector(c1, @selector(applicationAtCoordinate:))) {
        el = ((id (*)(id, SEL, CGPoint))objc_msgSend)((id)c1, @selector(applicationAtCoordinate:), pt);
        BApp(o, "AXElement applicationAtCoordinate: -> %p\n", el);
    }
    if (!el && c2 && class_respondsToSelector(c2, @selector(uiElementAtCoordinate:))) {
        el = ((id (*)(id, SEL, CGPoint))objc_msgSend)((id)c2, @selector(uiElementAtCoordinate:), pt);
        BApp(o, "AXUIElement uiElementAtCoordinate: -> %p\n", el);
    }
    if (!el) { BApp(o, "no element\n"); return; }
    axDesc(el, o, "hit", 0);
    if (press) {
        if (class_respondsToSelector(c1 ? (id)object_getClass(el) : NULL, @selector(performAction:))) {
            id rr = ((id (*)(id, SEL, id))objc_msgSend)(el, @selector(performAction:), @"AXPress");
            BApp(o, "performAction AXPress -> %p\n", rr);
        } else if (class_respondsToSelector((id)object_getClass(el), @selector(performAXAction:))) {
            id rr = ((id (*)(id, SEL, id))objc_msgSend)(el, @selector(performAXAction:), @"AXPress");
            BApp(o, "performAXAction AXPress -> %p\n", rr);
        } else {
            BApp(o, "no perform selector on %s\n", object_getClassName(el));
        }
    }
}

static void AXProbe(Buf *o) {
    static const char *nm[] = {
        "AXUIElementCreateApplication",
        "AXUIElementCreateApplicationWithPid",
        "_AXUIElementCreateApplication",
        "AXUIElementCreateSystemWide",
        "AXUIElementCreateWithPid",
        "AXElementCreateApplication",
        "AXUIElementCopyAttributeValue",
        "AXUIElementCopyElementAtPosition",
        "AXUIElementPerformAction",
        "AXIsProcessTrusted",
        "AXUIElementCreateElementArray",
        NULL
    };
    const char *paths[] = {
        "/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime",
        "/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities",
        "/usr/lib/libAccessibility.dylib",
        NULL
    };
    void *hs[4] = {0};
    for (int i = 0; paths[i] && i < 3; i++) hs[i] = dlopen(paths[i], RTLD_NOW);
    hs[3] = RTLD_DEFAULT;
    for (int i = 0; nm[i]; i++) {
        BApp(o, "%s:", nm[i]);
        for (int j = 0; j < 4; j++) {
            void *f = dlsym(hs[j], nm[i]);
            BApp(o, " [%d]=%p", j, f);
        }
        BApp(o, "\n");
    }
    const char *cls[] = {"AXElement", "AXApplication", "AXSystemWideElement", "AXPidElement",
                         "AXUIElement", "AXAuditElement", NULL};
    for (int i = 0; cls[i]; i++) {
        Class c = objc_getClass(cls[i]);
        BApp(o, "class %s=%p\n", cls[i], c);
        if (!c) continue;
        unsigned n = 0;
        Method *mf = class_copyMethodList(object_getClass(c), &n);
        BApp(o, "  +m %u:", n);
        for (unsigned k = 0; k < n && k < 12; k++) BApp(o, " %s", sel_getName(method_getName(mf[k])));
        BApp(o, "\n");
        free(mf);
        n = 0;
        mf = class_copyMethodList(c, &n);
        BApp(o, "  -m %u:", n);
        for (unsigned k = 0; k < n && k < 12; k++) BApp(o, " %s", sel_getName(method_getName(mf[k])));
        BApp(o, "\n");
        free(mf);
    }
}

static void SBAXRun(const char *line, Buf *o) {
    // 命令格式：
    //   pid <procname>
    //   ax <procname> [kw]        —— dump（带 kw 则标记命中）
    //   press <procname> <kw>     —— 找第一个命中并 AXPress
    char a[64] = {0}, b[128] = {0}, c[128] = {0};
    sscanf(line, "%63s %127s %127s", a, b, c);

    if (strcmp(a, "axprobe") == 0) { AXProbe(o); return; }

    if (strcmp(a, "ax2") == 0) { AX2Run(b, c, 0, o); return; }

    if (strcmp(a, "axapps") == 0) { AX2Run(NULL, NULL, 0, o); return; }

    if (strcmp(a, "axat") == 0) {
        AXAtRun(atof(b), atof(c), 0, o);
        return;
    }
    if (strcmp(a, "axpress") == 0) {
        AXAtRun(atof(b), atof(c), 1, o);
        return;
    }

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
