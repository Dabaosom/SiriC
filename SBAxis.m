// SBAxis.m — 1.7.5
// 观察层第二块：AX 语义查询（跨进程"看控件"，不注入目标 App）。
//
// 依据《读屏+触摸+App内操作_实现方案》§2.3 与 ios-mcp 逆向结论，走私有三件套：
//   _AXSApplicationAccessibilitySetEnabled(YES)   激活 AX 运行时
//   _AXUIElementCreateAppElementWithPid(pid)      建目标进程的元素（公开的
//                                                AXUIElementCreateApplication 在
//                                                SpringBoard 里拿不到东西，这是此前
//                                                "三根全 null" 的真因）
//   __AXSetRequestingClient(2) / _AXOverrideRequestingClientType(2)  伪装请求方
// 另加 _AXAddAssociatedPid(自身,目标) 双向关联 + AXUIElementSetMessagingTimeout(0.25)
// 防卡死。命中走公开的 AXUIElementCopyElementAtPosition（app 元素有效后它才工作）。
//
// 命令通道：SB_HOME_DIR/ax.cmd
//   state                只回状态（符号是否齐、AXS 是否启用、前台 pid）
//   front                回前台 App（pid / bundleId）
//   at X Y               点查：该坐标下的元素 role/label/value/frame
//   tapat X Y            点查 → 真实 tap（SBTouch）→ 400ms 后再点查，前后对比写回
//   attr X Y NAME        点查并读一个属性（NAME 为 AXLabel/AXValue/AXRole…）
// 结果：SB_HOME_DIR/ax_out.json + 日志一行 AX ...（UTF-8 文本按 C 字符串写，不用 @"…"）

#import "SiriBridge.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <pthread.h>
#include <sys/time.h>
#import <CoreFoundation/CoreFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#include <mach-o/dyld.h>
#include <sys/sysctl.h>

#define AX_CMD_FILE  SB_HOME_DIR "/ax.cmd"
#define AX_OUT_FILE  SB_HOME_DIR "/ax_out.json"
#define AX_HIT_FILE  SB_HOME_DIR "/ax_hit.json"
#define AX_ACT_FILE  SB_HOME_DIR "/ax_act.json"
#define AX_LAUNCH_FILE SB_HOME_DIR "/ax_launch.json"
#define AX_WHERE_FILE  SB_HOME_DIR "/ax_where.json"
#define AX_FLOW_CMD    SB_HOME_DIR "/flow.cmd"
#define AX_FLOW_FILE   SB_HOME_DIR "/ax_flow.json"
#define AX_QUERY_FILE  SB_HOME_DIR "/ax_query.json"
#define AX_OBJC_FILE   SB_HOME_DIR "/ax_objc.json"
#define AX_MARK_FILE SB_HOME_DIR "/ax_boot.txt"

typedef const struct __AXUIElement *AXEl;

typedef AXEl (*AXCreateAppPidFn)(int pid);
typedef int  (*AXCopyAttrFn)(AXEl, CFStringRef, CFTypeRef *);
typedef int  (*AXHitTestFn)(AXEl, float, float, AXEl *);
typedef int  (*AXSetTimeoutFn)(AXEl, float);
typedef int  (*AXPerformActionFn)(AXEl, CFStringRef);
typedef int  (*AXAddAssocFn)(int, int, int);
typedef void (*AXSetClientFn)(int);
typedef void (*AXOverrideClientTypeFn)(int);
typedef void (*AXSetEnabledFn)(int);
typedef int  (*AXEnabledFn)(void);
typedef int  (*AXFrontPidFn)(void);
typedef int  (*AXValueGetValueFn)(CFTypeRef, int, void *);
typedef AXEl (*AXSysCreateFn)(void);
typedef int  (*AXGetPidFn)(AXEl, int *);
typedef int  (*AXCopyNamesFn)(AXEl, CFArrayRef *);

static AXCreateAppPidFn        g_axCreateApp = NULL;
static AXCopyAttrFn            g_axCopyAttr = NULL;
static AXHitTestFn             g_axHitTest = NULL;
static AXSetTimeoutFn          g_axTimeout = NULL;
static AXPerformActionFn       g_axAction = NULL;
static AXAddAssocFn            g_axAddAssoc = NULL;
static AXSetClientFn           g_axSetClient = NULL;
static AXOverrideClientTypeFn  g_axOverrideType = NULL;
static AXSetEnabledFn          g_axSetEnabled = NULL;
static AXEnabledFn             g_axEnabled = NULL;
static AXFrontPidFn            g_axFrontPid = NULL;
static AXValueGetValueFn       g_axValueGet = NULL;
static AXSysCreateFn           g_axSysCreate = NULL;
static AXGetPidFn              g_axGetPid = NULL;
static AXCopyNamesFn           g_axCopyNames = NULL;
static void                   *g_axHandle = NULL;
static int                     g_axTargetPid = 0;   // ap 命令手工指定目标进程
static int                     g_axSkipFrontCheck = 0;  // actf 强制跳过"是否在屏幕上"的预检

static int g_axResolved = 0;
static int g_axActive = 0;      // AXS 已启用
static int g_axClientSet = 0;
static int g_axQueries = 0;
static int g_axHits = 0;
static int g_axFails = 0;
static pthread_t g_axThread;
static int g_axThreadUp = 0;

// ------------------------------------------------------------------ 工具

static CFStringRef axStr(const char *s) {
    if (!s) return NULL;
    return CFStringCreateWithCString(NULL, s, kCFStringEncodingUTF8);
}

static void axMarker(const char *tag) {
    FILE *f = fopen(AX_MARK_FILE, "a");
    if (!f) return;
    struct timeval tv;
    gettimeofday(&tv, NULL);
    fprintf(f, "%ld %s\n", (long)tv.tv_sec, tag);
    fflush(f);
    fclose(f);
}

static long axNowMs(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec * 1000L + tv.tv_usec / 1000L;
}

// CFString → C 缓冲（UTF-8）
static int axCFStrTo(char *dst, size_t cap, CFStringRef s) {
    if (!dst || cap == 0) return 0;
    dst[0] = 0;
    if (!s) return 0;
    if (CFGetTypeID(s) != CFStringGetTypeID()) {
        return 0;
    }
    return CFStringGetCString(s, dst, (CFIndex)cap, kCFStringEncodingUTF8) ? 1 : 0;
}

// 任意 CFType → 可读文本（字符串/数字/布尔）
static int axAnyTo(char *dst, size_t cap, CFTypeRef v) {
    if (!dst || cap == 0) return 0;
    dst[0] = 0;
    if (!v) return 0;

    CFTypeID t = CFGetTypeID(v);
    if (t == CFStringGetTypeID()) return axCFStrTo(dst, cap, (CFStringRef)v);
    if (t == CFNumberGetTypeID()) {
        double d = 0;
        if (CFNumberGetValue((CFNumberRef)v, kCFNumberDoubleType, &d)) {
            snprintf(dst, cap, "%g", d);
            return 1;
        }
        return 0;
    }
    if (t == CFBooleanGetTypeID()) {
        snprintf(dst, cap, "%d", CFBooleanGetValue((CFBooleanRef)v) ? 1 : 0);
        return 1;
    }
    if (t == CFArrayGetTypeID()) {
        snprintf(dst, cap, "[array %ld]", (long)CFArrayGetCount((CFArrayRef)v));
        return 1;
    }
    return 0;
}

// JSON 字符串转义
static void axEsc(char *dst, size_t cap, const char *src) {
    if (!dst || cap == 0) return;
    size_t j = 0;
    if (!src) { dst[0] = 0; return; }
    for (size_t i = 0; src[i] && j + 2 < cap; i++) {
        unsigned char c = (unsigned char)src[i];
        if (c == '"' || c == '\\') { dst[j++] = '\\'; dst[j++] = (char)c; }
        else if (c == '\n') { dst[j++] = '\\'; dst[j++] = 'n'; }
        else if (c == '\r') { dst[j++] = '\\'; dst[j++] = 'r'; }
        else if (c == '\t') { dst[j++] = '\\'; dst[j++] = 't'; }
        else if (c < 0x20) { dst[j++] = ' '; }
        else { dst[j++] = (char)c; }
    }
    dst[j] = 0;
}

// ------------------------------------------------------------------ 符号

static void *axDlopenAny(const char **cands, int n) {
    for (int i = 0; i < n; i++) {
        void *h = dlopen(cands[i], RTLD_LAZY);
        if (h) return h;
    }
    return NULL;
}

// 跨已加载镜像找符号：iOS 17 上 AXFrontBoardFocusedAppPID 只在 SpringBoardUI/AXFrontBoardUtils 这类导出表里
static void *axDlsymAcrossImages(const char *sym, char *hitName, size_t cap) {
    int cnt = _dyld_image_count();
    for (int i = 0; i < cnt; i++) {
        const char *path = _dyld_get_image_name(i);
        if (!path) continue;
        const char *base = strrchr(path, '/');
        base = base ? base + 1 : path;
        if (!strstr(base, "SpringBoard") && !strstr(base, "AX") && !strstr(base, "Accessibility"))
            continue;
        void *h = dlopen(path, RTLD_LAZY);
        if (!h) continue;
        void *p = dlsym(h, sym);
        if (p) {
            if (hitName && cap) {
                size_t n = strlen(base);
                if (n >= cap) n = cap - 1;
                memcpy(hitName, base, n);
                hitName[n] = 0;
            }
            return p;
        }
    }
    return NULL;
}

static int axResolve(void) {
    if (g_axResolved) return 1;
    g_axResolved = 1;

    const char *cands[8] = {
        "/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime",
        "/System/Library/PrivateFrameworks/Accessibility.framework/Accessibility",
        "/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities",
        "/System/Library/PrivateFrameworks/AccessibilitySharedSupport.framework/AccessibilitySharedSupport",
        "/System/Library/PrivateFrameworks/AccessibilityUI.framework/AccessibilityUI",
        "/usr/lib/libAccessibility.dylib",
        "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
        "/System/Library/Frameworks/HIServices.framework/HIServices"
    };

    void *h = axDlopenAny(cands, 8);
    g_axHandle = h;

    // 公共符号优先 RTLD_DEFAULT（若 SpringBoard 已加载 HIServices）
    g_axCopyAttr    = (AXCopyAttrFn)dlsym(RTLD_DEFAULT, "AXUIElementCopyAttributeValue");
    g_axHitTest     = (AXHitTestFn)dlsym(RTLD_DEFAULT, "AXUIElementCopyElementAtPosition");
    g_axTimeout     = (AXSetTimeoutFn)dlsym(RTLD_DEFAULT, "AXUIElementSetMessagingTimeout");
    g_axAction      = (AXPerformActionFn)dlsym(RTLD_DEFAULT, "AXUIElementPerformAction");
    g_axSetEnabled  = (AXSetEnabledFn)dlsym(RTLD_DEFAULT, "_AXSApplicationAccessibilitySetEnabled");
    g_axEnabled     = (AXEnabledFn)dlsym(RTLD_DEFAULT, "_AXSApplicationAccessibilityEnabled");

    if (h && !g_axCopyAttr)    g_axCopyAttr = (AXCopyAttrFn)dlsym(h, "AXUIElementCopyAttributeValue");
    if (h && !g_axHitTest)    g_axHitTest = (AXHitTestFn)dlsym(h, "AXUIElementCopyElementAtPosition");
    if (h && !g_axTimeout)    g_axTimeout = (AXSetTimeoutFn)dlsym(h, "AXUIElementSetMessagingTimeout");
    if (h && !g_axSetEnabled) g_axSetEnabled = (AXSetEnabledFn)dlsym(h, "_AXSApplicationAccessibilitySetEnabled");
    if (h && !g_axEnabled)    g_axEnabled = (AXEnabledFn)dlsym(h, "_AXSApplicationAccessibilityEnabled");

    const char *privateSyms[5] = { 0 };
    privateSyms[0] = "_AXUIElementCreateAppElementWithPid";
    privateSyms[1] = "__AXSetRequestingClient";
    privateSyms[2] = "_AXOverrideRequestingClientType";
    privateSyms[3] = "_AXAddAssociatedPid";
    privateSyms[4] = "AXFrontBoardFocusedAppPID";

    void *priv = h;
    if (!priv) priv = RTLD_DEFAULT;
    g_axCreateApp    = (AXCreateAppPidFn)dlsym(priv, privateSyms[0]);
    g_axSetClient    = (AXSetClientFn)dlsym(priv, privateSyms[1]);
    g_axOverrideType = (AXOverrideClientTypeFn)dlsym(priv, privateSyms[2]);
    g_axAddAssoc     = (AXAddAssocFn)dlsym(priv, privateSyms[3]);
    g_axFrontPid     = (AXFrontPidFn)dlsym(priv, privateSyms[4]);
    if (!g_axFrontPid) {
        char nm[64] = { 0 };
        void *p = axDlsymAcrossImages("AXFrontBoardFocusedAppPID", nm, sizeof nm);
        if (p) { g_axFrontPid = (AXFrontPidFn)p; SBLogSync("AX frontPid src=%s", nm); }
    }
    if (!g_axCreateApp) {
        char nm[64] = { 0 };
        void *p = axDlsymAcrossImages("_AXUIElementCreateAppElementWithPid", nm, sizeof nm);
        if (p) { g_axCreateApp = (AXCreateAppPidFn)p; SBLogSync("AX createApp src=%s", nm); }
    }

    g_axValueGet = (AXValueGetValueFn)dlsym(RTLD_DEFAULT, "AXValueGetValue");    if (!g_axValueGet && h) g_axValueGet = (AXValueGetValueFn)dlsym(h, "AXValueGetValue");

    g_axSysCreate = (AXSysCreateFn)dlsym(RTLD_DEFAULT, "AXUIElementCreateSystemWide");
    if (!g_axSysCreate && h) g_axSysCreate = (AXSysCreateFn)dlsym(h, "AXUIElementCreateSystemWide");
    g_axGetPid = (AXGetPidFn)dlsym(RTLD_DEFAULT, "AXUIElementGetPid");
    if (!g_axGetPid && h) g_axGetPid = (AXGetPidFn)dlsym(h, "AXUIElementGetPid");
    g_axCopyNames = (AXCopyNamesFn)dlsym(RTLD_DEFAULT, "AXUIElementCopyAttributeNames");
    if (!g_axCopyNames && h) g_axCopyNames = (AXCopyNamesFn)dlsym(h, "AXUIElementCopyAttributeNames");

    SBLogSync("AX sym create=%d copy=%d hit=%d timeout=%d setEn=%d en=%d client=%d over=%d assoc=%d front=%d h=%d",
              g_axCreateApp ? 1 : 0, g_axCopyAttr ? 1 : 0, g_axHitTest ? 1 : 0,
              g_axTimeout ? 1 : 0, g_axSetEnabled ? 1 : 0, g_axEnabled ? 1 : 0,
              g_axSetClient ? 1 : 0, g_axOverrideType ? 1 : 0, g_axAddAssoc ? 1 : 0,
              g_axFrontPid ? 1 : 0, h ? 1 : 0);
    return 1;
}

// 激活运行时 + 设请求方（只做一次；失败也继续，最多是查询全空）
static void axActivate(void) {
    axResolve();
    if (g_axClientSet) return;

    if (g_axSetEnabled) {
        g_axSetEnabled(1);
    }
    int en = -1;
    if (g_axEnabled) en = g_axEnabled() ? 1 : 0;
    g_axActive = (en == 1) ? 1 : (g_axSetEnabled ? 1 : 0);

    if (g_axOverrideType) g_axOverrideType(2);
    if (g_axSetClient) g_axSetClient(2);
    g_axClientSet = 1;

    SBLogSync("AX activate set=%d enabled=%d override=%d client=%d",
              g_axSetEnabled ? 1 : 0, en, g_axOverrideType ? 1 : 0, g_axSetClient ? 1 : 0);
}

// 前向声明（axFrontApp 里要用 axAttrValue，函数定义在后面）
static CFTypeRef axAttrValue(AXEl el, const char *name);

// ------------------------------------------------------------------ 前台 App

typedef struct {
    int pid;
    char bundle[128];
} AXFront;

static int axFrontApp(AXFront *out) {
    if (!out) return -1;
    out->pid = 0;
    out->bundle[0] = 0;

    axActivate();

    // 0) 手工指定（ap 命令），调试与定向查询用
    if (g_axTargetPid > 0) {
        out->pid = g_axTargetPid;
        return 0;
    }

    // 1) 系统级元素的「聚焦 App」属性（AX 活性正常时最可靠）
    if (g_axSysCreate && g_axGetPid && g_axCopyAttr) {
        AXEl sw = NULL;
        @try { sw = g_axSysCreate(); } @catch (NSException *e) { (void)e; sw = NULL; }
        if (sw) {
            CFTypeRef fa = axAttrValue(sw, "AXFocusedApplication");
            if (fa) {
                int pid = 0;
                @try { g_axGetPid((AXEl)fa, &pid); } @catch (NSException *e) { (void)e; pid = 0; }
                CFRelease(fa);
                if (pid > 0) {
                    out->pid = pid;
                    SBLogSync("AX front via systemwide pid=%d", pid);
                    return 0;
                }
            }
            CFRelease(sw);
        }
    }

    // 2) SpringBoard 私有：_accessibilityFrontMostApplication
    Class sbCls = objc_getClass("SpringBoard");
    if (sbCls) {
        id sb = ((id (*)(id, SEL))objc_msgSend)((id)sbCls, sel_registerName("sharedApplication"));
        if (sb) {
            id fm = NULL;
            @try {
                fm = ((id (*)(id, SEL))objc_msgSend)(sb, sel_registerName("_accessibilityFrontMostApplication"));
            } @catch (NSException *e) { (void)e; fm = NULL; }
            if (fm) {
                int pid = ((int (*)(id, SEL))objc_msgSend)(fm, sel_registerName("pid"));
                if (pid > 0) {
                    out->pid = pid;
                    id bid = ((id (*)(id, SEL))objc_msgSend)(fm, sel_registerName("bundleIdentifier"));
                    axCFStrTo(out->bundle, sizeof(out->bundle), (CFStringRef)bid);
                    if (out->bundle[0]) return 0;
                }
            }
        }
    }

    // 3) AXFrontBoardFocusedAppPID
    if (out->pid <= 0 && g_axFrontPid) {
        int pid = g_axFrontPid();
        if (pid > 0) out->pid = pid;
    }

    if (out->pid <= 0) return -1;
    return 0;
}

// ------------------------------------------------------------------ 建元素 + 查询

static AXEl axAppElement(int pid) {
    axActivate();
    if (pid <= 0) return NULL;

    // 建元素前先把默认消息超时压下来（系统级元素上设，影响后续 IPC 等待）
    if (g_axSysCreate && g_axTimeout) {
        AXEl sw = NULL;
        @try { sw = g_axSysCreate(); } @catch (NSException *e) { (void)e; sw = NULL; }
        if (sw) { g_axTimeout(sw, 0.3f); CFRelease(sw); }
    }

    AXEl el = NULL;
    if (g_axCreateApp) {
        el = g_axCreateApp(pid);
    }
    if (!el) {
        AXCreateAppPidFn pub = (AXCreateAppPidFn)dlsym(RTLD_DEFAULT, "AXUIElementCreateApplication");
        if (pub) el = pub(pid);
    }
    if (!el) return NULL;

    // 双向关联（拿不到返回值就看日志）
    if (g_axAddAssoc) {
        int r1 = g_axAddAssoc((int)getpid(), pid, 1);
        int r2 = g_axAddAssoc(pid, (int)getpid(), 1);
        SBLogSync("AX assoc self→%d=%d %d→self=%d", pid, r1, pid, r2);
    }
    if (g_axTimeout) g_axTimeout(el, 0.25f);
    return el;
}

static CFTypeRef axAttrValue(AXEl el, const char *name) {
    if (!el || !name || !g_axCopyAttr) return NULL;
    CFStringRef k = axStr(name);
    if (!k) return NULL;
    CFTypeRef v = NULL;
    g_axCopyAttr(el, k, &v);
    CFRelease(k);
    return v;
}

typedef struct {
    int ok;
    char role[64];
    char subrole[64];
    char label[256];
    char value[256];
    char title[256];
    char ident[256];
    double x, y, w, h;
    int hasFrame;
    int enabled;
} AXElInfo;

static int axValueGet(CFTypeRef v, int want, void *out) {
    // want: 1=CGPoint 2=CGSize 3=CGRect（对应 kAXValueCGPointType/CGSize/CGRect）
    if (!v || !g_axValueGet) return 0;
    return g_axValueGet(v, want, out) ? 1 : 0;
}

static int axRectGet(CFTypeRef v, CGRect *out) { return axValueGet(v, 3, out); }
static int axPointGet(CFTypeRef v, CGPoint *out) { return axValueGet(v, 1, out); }

static CFTypeRef axCopy(AXEl el, CFStringRef key) {
    if (!el || !key || !g_axCopyAttr) return NULL;
    CFTypeRef v = NULL;
    g_axCopyAttr(el, key, &v);
    return v;
}

// kAXXCAttribute* 是 CFStringRef* 形态的符号；值可能是数字字符串（要转成数值 key），也可能是属性名
static CFStringRef axKeyFromSymbol(const char *symName, int *isNumeric) {
    if (!g_axResolved) axResolve();
    if (isNumeric) *isNumeric = 0;

    CFStringRef *p = NULL;
    if (g_axHandle) p = (CFStringRef *)dlsym(g_axHandle, symName);
    if (!p) p = (CFStringRef *)dlsym(RTLD_DEFAULT, symName);
    if (!p || !*p) return NULL;

    CFStringRef s = *p;
    if (CFGetTypeID(s) != CFStringGetTypeID()) return NULL;
    int num = CFStringGetIntValue(s);
    if (num > 0) {
        if (isNumeric) *isNumeric = 1;
        return (CFStringRef)(uintptr_t)num;
    }
    return s;
}

static void axInfoOf(AXEl el, AXElInfo *info) {
    if (!info) return;
    memset(info, 0, sizeof(*info));
    if (!el) return;

    CFTypeRef r = axAttrValue(el, "AXRole");
    axAnyTo(info->role, sizeof(info->role), r);
    if (r) CFRelease(r);

    CFTypeRef sr = axAttrValue(el, "AXSubrole");
    axAnyTo(info->subrole, sizeof(info->subrole), sr);
    if (sr) CFRelease(sr);

    CFTypeRef l = axAttrValue(el, "AXLabel");
    axAnyTo(info->label, sizeof(info->label), l);
    if (l) CFRelease(l);

    CFTypeRef t = axAttrValue(el, "AXTitle");
    axAnyTo(info->title, sizeof(info->title), t);
    if (t) CFRelease(t);

    CFTypeRef idn = axAttrValue(el, "AXIdentifier");
    axAnyTo(info->ident, sizeof(info->ident), idn);
    if (idn) CFRelease(idn);

    CFTypeRef v = axAttrValue(el, "AXValue");
    axAnyTo(info->value, sizeof(info->value), v);
    if (v) CFRelease(v);

    CFTypeRef en = axAttrValue(el, "AXEnabled");
    if (en) {
        info->enabled = (CFGetTypeID(en) == CFBooleanGetTypeID())
                      ? (CFBooleanGetValue((CFBooleanRef)en) ? 1 : 0)
                      : -1;
        CFRelease(en);
    } else {
        info->enabled = -1;
    }

    CGPoint p = CGPointZero;
    CGSize s = CGSizeZero;
    CFTypeRef pos = axAttrValue(el, "AXPosition");
    if (pos) {
        axValueGet(pos, 1, &p);
        CFRelease(pos);
    }
    CFTypeRef sz = axAttrValue(el, "AXSize");
    if (sz) {
        axValueGet(sz, 2, &s);
        CFRelease(sz);
    }
    if (s.width > 0 || s.height > 0) {
        info->x = p.x; info->y = p.y; info->w = s.width; info->h = s.height;
        info->hasFrame = 1;
    }

    info->ok = (info->role[0] || info->label[0] || info->value[0] || info->ident[0]) ? 1 : 0;
}

// 点查：app 元素的坐标是"屏幕点、左上原点"，与 SBTouch 同一套
static AXEl axHitAt(AXEl app, double x, double y) {
    if (!app || !g_axHitTest) return NULL;
    AXEl out = NULL;
    @try {
        g_axHitTest(app, (float)x, (float)y, &out);
    } @catch (NSException *e) { (void)e; out = NULL; }
    return out;
}

// ------------------------------------------------------------------ 输出

static void axWriteJSON(const char *mode, double qx, double qy, const AXFront *fr,
                        const AXElInfo *a, const AXElInfo *b) {
    char jRole[80], jLabel[300], jVal[300], jIdent[300], jTitle[300];
    char jRole2[80], jLabel2[300], jVal2[300], jIdent2[300];
    axEsc(jRole, sizeof(jRole), a ? a->role : "");
    axEsc(jLabel, sizeof(jLabel), a ? a->label : "");
    axEsc(jVal, sizeof(jVal), a ? a->value : "");
    axEsc(jIdent, sizeof(jIdent), a ? a->ident : "");
    axEsc(jTitle, sizeof(jTitle), a ? a->title : "");
    axEsc(jRole2, sizeof(jRole2), b ? b->role : "");
    axEsc(jLabel2, sizeof(jLabel2), b ? b->label : "");
    axEsc(jVal2, sizeof(jVal2), b ? b->value : "");
    axEsc(jIdent2, sizeof(jIdent2), b ? b->ident : "");

    FILE *f = fopen(AX_OUT_FILE, "w");
    if (!f) return;

    fprintf(f, "{\"ok\":%d,\"mode\":\"%s\",\"point\":[%.1f,%.1f],\"pid\":%d,\"bundle\":\"%s\",",
            (a && a->ok) ? 1 : 0, mode ? mode : "?", qx, qy,
            fr ? fr->pid : 0, fr ? fr->bundle : "");

    if (a) {
        fprintf(f, "\"element\":{\"role\":\"%s\",\"label\":\"%s\",\"value\":\"%s\",\"identifier\":\"%s\",\"title\":\"%s\",\"enabled\":%d",
                jRole, jLabel, jVal, jIdent, jTitle, a->enabled);
        if (a->hasFrame) fprintf(f, ",\"frame\":[%.1f,%.1f,%.1f,%.1f]", a->x, a->y, a->w, a->h);
        fprintf(f, "},");
    } else {
        fprintf(f, "\"element\":null,");
    }

    if (b) {
        fprintf(f, "\"after\":{\"role\":\"%s\",\"label\":\"%s\",\"value\":\"%s\",\"identifier\":\"%s\"",
                jRole2, jLabel2, jVal2, jIdent2);
        if (b->hasFrame) fprintf(f, ",\"frame\":[%.1f,%.1f,%.1f,%.1f]", b->x, b->y, b->w, b->h);
        fprintf(f, "},");
    }

    fprintf(f, "\"queries\":%d,\"hits\":%d,\"fails\":%d}\n", g_axQueries, g_axHits, g_axFails);
    fflush(f);
    fclose(f);
}

static int axDoQuery(double x, double y, const char *mode, int doTap, AXElInfo *outBefore, AXElInfo *outAfter) {
    AXFront fr = { 0, "" };
    int hasFront = axFrontApp(&fr);

    AXEl app = NULL;
    if (hasFront == 0) app = axAppElement(fr.pid);
    if (!app) {
        g_axFails++;
        SBLogSync("AX query FAIL no-app pid=%d", fr.pid);
        return -1;
    }

    long t0 = axNowMs();
    AXEl hit = axHitAt(app, x, y);
    g_axQueries++;
    if (hit) g_axHits++;

    AXElInfo info;
    axInfoOf(hit, &info);

    SBLogSync("AX at %.0f,%.0f pid=%d bundle=%s -> role=%s label=%s value=%s ident=%s frame=%d(%g,%g,%g,%g) ms=%ld",
              x, y, fr.pid, fr.bundle,
              info.role, info.label, info.value, info.ident,
              info.hasFrame, info.x, info.y, info.w, info.h, axNowMs() - t0);

    if (outBefore) *outBefore = info;

    if (doTap) {
        int rc = SBTouchTap(x, y);
        SBLogSync("AX tap %.0f,%.0f rc=%d", x, y, rc);
        usleep(400000);

        AXEl hit2 = axHitAt(app, x, y);
        AXElInfo info2;
        axInfoOf(hit2, &info2);
        SBLogSync("AX after %.0f,%.0f -> role=%s label=%s value=%s ident=%s",
                  x, y, info2.role, info2.label, info2.value, info2.ident);
        if (outAfter) *outAfter = info2;
    }

    axWriteJSON(mode, x, y, &fr, &info, doTap ? outAfter : NULL);
    return hit ? 0 : -2;
}

// ------------------------------------------------------------------ 命令

// 诊断：每个符号到底在哪个 dylib 里（dladdr）+ SpringBoard 侧类/方法探测
static void axDlProbe(void) {
    const char *syms[16] = {
        "_AXUIElementCreateAppElementWithPid", "__AXSetRequestingClient",
        "_AXOverrideRequestingClientType", "_AXAddAssociatedPid",
        "AXValueGetValue", "AXUIElementCopyAttributeValue",
        "AXUIElementCopyAttributeNames", "AXUIElementCopyElementAtPosition",
        "_AXSApplicationAccessibilitySetEnabled", "_AXSApplicationAccessibilityEnabled",
        "AXUIElementCreateSystemWide", "AXUIElementGetPid",
        "AXUIElementPerformAction", "AXUIElementSetMessagingTimeout",
        "AXUIElementCopyApplicationAndContextAtPosition", "_AXUIElementCopyApplicationAndContextAtPosition"
    };
    for (int i = 0; i < 16; i++) {
        void *p = dlsym(RTLD_DEFAULT, syms[i]);
        if (!p && g_axHandle) p = dlsym(g_axHandle, syms[i]);
        if (!p) { SBLogSync("AXP sym %s MISS", syms[i]); continue; }
        Dl_info di;
        memset(&di, 0, sizeof(di));
        if (dladdr(p, &di) && di.dli_fname) {
            SBLogSync("AXP sym %s -> %s", syms[i], di.dli_fname);
        } else {
            SBLogSync("AXP sym %s -> (addr only)", syms[i]);
        }
    }

    const char *classes[4] = { "SBApplicationController", "SBUIController", "SpringBoard", "SBWorkspace" };
    const char *sels[8] = { "sharedInstance", "applications", "allApplications",
                            "frontmostApplication", "_frontMostApplication", "_accessibilityFrontMostApplication",
                            "applicationWithBundleIdentifier:", "mainWorkspace" };
    for (int c = 0; c < 4; c++) {
        Class cls = objc_getClass(classes[c]);
        if (!cls) { SBLogSync("AXP cls %s MISS", classes[c]); continue; }
        for (int s = 0; s < 8; s++) {
            SEL sel = sel_registerName(sels[s]);
            BOOL hasInst = ((BOOL (*)(id, SEL, SEL))objc_msgSend)((id)cls, sel_registerName("instancesRespondToSelector:"), sel);
            BOOL hasCls  = ((BOOL (*)(id, SEL, SEL))objc_msgSend)(object_getClass((id)cls), sel_registerName("instancesRespondToSelector:"), sel);
            if (hasInst || hasCls) SBLogSync("AXP sel %s %s inst=%d cls=%d", classes[c], sels[s], hasInst ? 1 : 0, hasCls ? 1 : 0);
        }
    }
}

// 诊断：元素支持哪些属性名（空 = 没有权限或元素无效）
static void axNamesAt(int hasPoint, double x, double y) {
    axActivate();
    AXFront fr = { 0, "" };
    axFrontApp(&fr);
    AXEl app = fr.pid > 0 ? axAppElement(fr.pid) : NULL;
    if (!app) { SBLogSync("AXN no-app"); return; }

    if (!g_axCopyNames) { SBLogSync("AXN no-sym"); return; }

    AXEl target = app;
    AXEl hit = hasPoint ? axHitAt(app, x, y) : NULL;
    if (hit) target = hit;

    CFArrayRef names = NULL;
    int rc = g_axCopyNames(target, &names);
    long n = names ? (long)CFArrayGetCount(names) : -1;
    SBLogSync("AXN rc=%d n=%ld target=%s pid=%d", rc, n, hit ? "hit" : "app", fr.pid);

    if (names) {
        for (long i = 0; i < n && i < 30; i++) {
            CFStringRef s = (CFStringRef)CFArrayGetValueAtIndex(names, i);
            char b[96];
            axCFStrTo(b, sizeof(b), s);
            SBLogSync("AXN name %ld = %s", i, b);
        }
        CFRelease(names);
    }
}

// 诊断：逐个属性名试读（看哪些 rc=0 有值）
static void axAttrsAt(int hasPoint, double x, double y) {
    axActivate();
    AXFront fr = { 0, "" };
    axFrontApp(&fr);
    AXEl app = fr.pid > 0 ? axAppElement(fr.pid) : NULL;
    if (!app) { SBLogSync("AXT no-app"); return; }

    AXEl target = app;
    AXEl hit = hasPoint ? axHitAt(app, x, y) : NULL;
    if (hit) target = hit;
    SBLogSync("AXT target=%s pid=%d copy=%d", hit ? "hit" : "app", fr.pid, g_axCopyAttr ? 1 : 0);

    const char *names[18] = {
        "AXRole", "AXSubrole", "AXLabel", "AXValue", "AXTitle", "AXIdentifier",
        "AXEnabled", "AXFrame", "AXPosition", "AXSize", "AXChildren",
        "AXChildrenInNavigationOrder", "AXWindow", "AXVisible", "AXTraits",
        "AXRoleDescription", "AXElementBusy", "AXFocusedUIElement"
    };
    for (int i = 0; i < 18; i++) {
        CFStringRef k = axStr(names[i]);
        CFTypeRef v = NULL;
        int rc = g_axCopyAttr ? g_axCopyAttr(target, k, &v) : -999;
        if (k) CFRelease(k);
        char b[160];
        b[0] = 0;
        if (v) {
            CFTypeID t = CFGetTypeID(v);
            if (t == CFStringGetTypeID()) axCFStrTo(b, sizeof(b), (CFStringRef)v);
            else if (t == CFArrayGetTypeID()) snprintf(b, sizeof(b), "[array %ld]", (long)CFArrayGetCount((CFArrayRef)v));
            else if (t == CFNumberGetTypeID()) axAnyTo(b, sizeof(b), v);
            else if (t == CFBooleanGetTypeID()) axAnyTo(b, sizeof(b), v);
            else snprintf(b, sizeof(b), "<type %lu>", (unsigned long)t);
            CFRelease(v);
        }
        SBLogSync("AXT %s rc=%d val=%s", names[i], rc, b);
    }
}

// 诊断：数值属性 ID（ios-mcp 的做法：整数直接当 CFStringRef 用）
static void axNumericProbe(void) {
    axActivate();
    AXFront fr = { 0, "" };
    axFrontApp(&fr);
    AXEl app = fr.pid > 0 ? axAppElement(fr.pid) : NULL;
    if (!app) { SBLogSync("AXN2 no-app"); return; }

    int ids[10] = { 3015, 3022, 3025, 3029, 3031, 3032, 3001, 3002, 3003, 3004 };
    for (int i = 0; i < 10; i++) {
        CFTypeRef v = NULL;
        int rc = g_axCopyAttr ? g_axCopyAttr(app, (CFStringRef)(uintptr_t)ids[i], &v) : -999;
        char b[160];
        b[0] = 0;
        if (v) {
            CFTypeID t = CFGetTypeID(v);
            if (t == CFStringGetTypeID()) axCFStrTo(b, sizeof(b), (CFStringRef)v);
            else if (t == CFArrayGetTypeID()) snprintf(b, sizeof(b), "[array %ld]", (long)CFArrayGetCount((CFArrayRef)v));
            else snprintf(b, sizeof(b), "<type %lu>", (unsigned long)t);
            CFRelease(v);
        }
        SBLogSync("AXN2 id=%d rc=%d val=%s", ids[i], rc, b);
    }
}

// 诊断：系统级元素 → 聚焦 App / 聚焦元素
static void axSystemWide(void) {
    axActivate();
    if (!g_axSysCreate) { SBLogSync("AXW no-sym"); return; }
    AXEl sw = NULL;
    @try { sw = g_axSysCreate(); } @catch (NSException *e) { (void)e; }
    if (!sw) { SBLogSync("AXW systemwide null"); return; }

    const char *attrs[2] = { "AXFocusedApplication", "AXFocusedUIElement" };
    for (int i = 0; i < 2; i++) {
        CFStringRef k = axStr(attrs[i]);
        CFTypeRef v = NULL;
        int rc = g_axCopyAttr ? g_axCopyAttr(sw, k, &v) : -999;
        if (k) CFRelease(k);
        if (!v) { SBLogSync("AXW %s rc=%d null", attrs[i], rc); continue; }
        int pid = 0;
        @try { if (g_axGetPid) g_axGetPid((AXEl)v, &pid); } @catch (NSException *e) { (void)e; }
        CFStringRef k2 = axStr("AXRole");
        CFTypeRef v2 = NULL;
        int rc2 = g_axCopyAttr ? g_axCopyAttr((AXEl)v, k2, &v2) : -999;
        char b[96];
        axAnyTo(b, sizeof(b), v2);
        if (v2) CFRelease(v2);
        if (k2) CFRelease(k2);
        SBLogSync("AXW %s rc=%d pid=%d roleRc=%d role=%s", attrs[i], rc, pid, rc2, b);
        CFRelease(v);
    }
    CFRelease(sw);
}

// 诊断：kAXXCAttribute* 符号里的真实属性键（是名字还是数字 ID）
static CFStringRef axKeyFromSymbol(const char *symName, int *isNumeric);

static void axSymProbe(void) {
    const char *names[10] = {
        "kAXXCAttributeLabel", "kAXXCAttributeValue", "kAXXCAttributeElementType",
        "kAXXCAttributeFrame", "kAXXCAttributeVisibleFrame", "kAXXCAttributeIdentifier",
        "kAXXCAttributeTraits", "kAXXCAttributeIsVisible", "kAXXCAttributeIsUserInteractionEnabled",
        "kAXXCAttributeChildren"
    };
    for (int i = 0; i < 10; i++) {
        int num = 0;
        CFStringRef k = axKeyFromSymbol(names[i], &num);
        char b[96];
        b[0] = 0;
        if (k) axCFStrTo(b, sizeof(b), k);
        SBLogSync("AXS %s numeric=%d key=%s", names[i], num, b);
    }
}

// 文案：2001 是 label；为空时回落 2006（value/placeholder，如搜索框的"搜索"）
static void axLabelOf(AXEl el, char *out, size_t cap) {
    if (!out || cap == 0) return;
    out[0] = 0;
    CFTypeRef v = axCopy(el, (CFStringRef)(uintptr_t)2001);
    if (v) { axAnyTo(out, cap, v); CFRelease(v); }
    if (out[0]) return;
    v = axCopy(el, (CFStringRef)(uintptr_t)2006);
    if (v) { axAnyTo(out, cap, v); CFRelease(v); }
}

// 树：元素文案 2001(+2006 回落)、几何 2057/2007、traits 2041；同时写 ax_out.json
static void axDumpTree(void) {
    axActivate();
    AXFront fr = { 0, "" };
    axFrontApp(&fr);
    AXEl app = fr.pid > 0 ? axAppElement(fr.pid) : NULL;
    if (!app) { SBLogSync("AXD no-app"); return; }

    FILE *jf = fopen(AX_OUT_FILE, "w");
    if (jf) {
        fprintf(jf, "{\"ok\":1,\"mode\":\"dump\",\"pid\":%d,\"bundle\":\"%s\",\"elements\":[",
                fr.pid, fr.bundle);
    }

    int total = 0;
    for (int pass = 0; pass < 2; pass++) {
        int id = pass == 0 ? 3015 : 3022;
        CFTypeRef arr = NULL;
        int rc = g_axCopyAttr ? g_axCopyAttr(app, (CFStringRef)(uintptr_t)id, &arr) : -999;
        long n = (arr && CFGetTypeID(arr) == CFArrayGetTypeID()) ? (long)CFArrayGetCount((CFArrayRef)arr) : -1;
        SBLogSync("AXD pass=%d id=%d rc=%d n=%ld", pass, id, rc, n);
        if (n <= 0) { if (arr) CFRelease(arr); continue; }

        for (long i = 0; i < n && i < 40; i++) {
            AXEl el = (AXEl)CFArrayGetValueAtIndex((CFArrayRef)arr, i);
            if (!el) continue;

            char lbl[200]; axLabelOf(el, lbl, sizeof(lbl));
            char tr[96]; tr[0] = 0;
            CFTypeRef tv = axCopy(el, (CFStringRef)(uintptr_t)2041);
            if (tv) { axAnyTo(tr, sizeof(tr), tv); CFRelease(tv); }

            CGRect rc2 = CGRectZero;
            CFTypeRef frv = axCopy(el, (CFStringRef)(uintptr_t)2057);
            if (frv) { axRectGet(frv, &rc2); CFRelease(frv); }
            CGPoint ctr = CGPointZero;
            CFTypeRef cp = axCopy(el, (CFStringRef)(uintptr_t)2007);
            if (cp) { axPointGet(cp, &ctr); CFRelease(cp); }

            SBLogSync("AXL p=%d i=%ld label='%s' traits='%s' frame=%g,%g,%g,%g center=%g,%g",
                      pass, i, lbl, tr, rc2.origin.x, rc2.origin.y, rc2.size.width, rc2.size.height,
                      ctr.x, ctr.y);

            if (jf) {
                char jl[300], jt[120];
                axEsc(jl, sizeof(jl), lbl);
                axEsc(jt, sizeof(jt), tr);
                fprintf(jf, "%s{\"i\":%ld,\"p\":%d,\"label\":\"%s\",\"traits\":\"%s\",\"frame\":[%.1f,%.1f,%.1f,%.1f],\"center\":[%.1f,%.1f]}",
                        total ? "," : "", i, pass, jl, jt,
                        rc2.origin.x, rc2.origin.y, rc2.size.width, rc2.size.height, ctr.x, ctr.y);
            }
            total++;
        }
        CFRelease(arr);
    }
    if (jf) {
        fprintf(jf, "],\"count\":%d}\n", total);
        fflush(jf);
        fclose(jf);
    }
    SBLogSync("AXD done total=%d", total);
}

// 滚动读整页：每屏 dump 一次，然后向上滑一屏，最多 8 屏
static void axScrollDump(int pages) {
    if (pages < 1) pages = 1;
    if (pages > 8) pages = 8;
    axActivate();
    AXFront fr = { 0, "" };
    axFrontApp(&fr);
    AXEl app = fr.pid > 0 ? axAppElement(fr.pid) : NULL;
    if (!app) { SBLogSync("AXS no-app"); return; }

    FILE *jf = fopen(AX_OUT_FILE, "w");
    if (jf) fprintf(jf, "{\"ok\":1,\"mode\":\"scrolldump\",\"pid\":%d,\"bundle\":\"%s\",\"elements\":[",
                    fr.pid, fr.bundle);

    int total = 0;
    for (int pg = 0; pg < pages; pg++) {
        for (int pass = 0; pass < 2; pass++) {
            int id = pass == 0 ? 3015 : 3022;
            CFTypeRef arr = axCopy(app, (CFStringRef)(uintptr_t)id);
            long n = (arr && CFGetTypeID(arr) == CFArrayGetTypeID()) ? (long)CFArrayGetCount((CFArrayRef)arr) : -1;
            if (n <= 0 || !arr) { if (arr) CFRelease(arr); continue; }

            for (long i = 0; i < n && i < 40; i++) {
                AXEl el = (AXEl)CFArrayGetValueAtIndex((CFArrayRef)arr, i);
                if (!el) continue;
                char lbl[200]; axLabelOf(el, lbl, sizeof(lbl));
                char tr[96]; tr[0] = 0;
                CFTypeRef tv = axCopy(el, (CFStringRef)(uintptr_t)2041);
                if (tv) { axAnyTo(tr, sizeof(tr), tv); CFRelease(tv); }
                CGRect r2 = CGRectZero;
                CFTypeRef frv = axCopy(el, (CFStringRef)(uintptr_t)2057);
                if (frv) { axRectGet(frv, &r2); CFRelease(frv); }
                CGPoint c2 = CGPointZero;
                CFTypeRef cp = axCopy(el, (CFStringRef)(uintptr_t)2007);
                if (cp) { axPointGet(cp, &c2); CFRelease(cp); }

                SBLogSync("AXS s=%d p=%d i=%ld label='%s' frame=%g,%g,%g,%g center=%g,%g",
                          pg, pass, i, lbl, r2.origin.x, r2.origin.y, r2.size.width, r2.size.height, c2.x, c2.y);

                if (jf) {
                    char jl[300], jt[120];
                    axEsc(jl, sizeof(jl), lbl);
                    axEsc(jt, sizeof(jt), tr);
                    fprintf(jf, "%s{\"s\":%d,\"p\":%d,\"i\":%ld,\"label\":\"%s\",\"traits\":\"%s\",\"frame\":[%.1f,%.1f,%.1f,%.1f],\"center\":[%.1f,%.1f]}",
                            total ? "," : "", pg, pass, i, jl, jt,
                            r2.origin.x, r2.origin.y, r2.size.width, r2.size.height, c2.x, c2.y);
                }
                total++;
            }
            CFRelease(arr);
        }
        if (pg + 1 < pages) {
            int r = SBTouchSwipe(215, 780, 215, 320, 320);
            SBLogSync("AXS swipe s=%d r=%d", pg, r);
            usleep(900000);
        }
    }
    if (jf) { fprintf(jf, "],\"count\":%d}\n", total); fflush(jf); fclose(jf); }
    SBLogSync("AXS done pages=%d total=%d", pages, total);
}

// 按文案找元素（prefix/substr 匹配），可顺带点击中心点
static int axFindLabel(const char *needle, int doTap) {
    if (!needle || !*needle) { SBLogSync("AXF empty"); return 0; }
    axActivate();
    AXFront fr = { 0, "" };
    axFrontApp(&fr);
    AXEl app = fr.pid > 0 ? axAppElement(fr.pid) : NULL;
    if (!app) { SBLogSync("AXF no-app"); return 0; }

    int hits = 0;
    int tapped = 0;
    for (int pass = 0; pass < 2 && !tapped; pass++) {
        int id = pass == 0 ? 3015 : 3022;
        CFTypeRef arr = axCopy(app, (CFStringRef)(uintptr_t)id);
        long n = (arr && CFGetTypeID(arr) == CFArrayGetTypeID()) ? (long)CFArrayGetCount((CFArrayRef)arr) : -1;
        if (n <= 0 || !arr) { if (arr) CFRelease(arr); continue; }

        for (long i = 0; i < n && hits < 8 && !tapped; i++) {
            AXEl el = (AXEl)CFArrayGetValueAtIndex((CFArrayRef)arr, i);
            if (!el) continue;
            char lbl[200]; axLabelOf(el, lbl, sizeof(lbl));
            if (!strstr(lbl, needle)) continue;

            CGPoint ctr = CGPointZero;
            CFTypeRef cp = axCopy(el, (CFStringRef)(uintptr_t)2007);
            if (cp) { axPointGet(cp, &ctr); CFRelease(cp); }

            SBLogSync("AXF hit p=%d i=%ld label='%s' center=%g,%g", pass, i, lbl, ctr.x, ctr.y);
            hits++;
            if (doTap && ctr.x > 0 && ctr.y > 0) {
                int r = SBTouchTap(ctr.x, ctr.y);
                SBLogSync("AXF tap %.0f,%.0f r=%d", ctr.x, ctr.y, r);
                tapped = 1;
            }
        }
        CFRelease(arr);
    }
    SBLogSync("AXF done hits=%d", hits);
    return hits;
}

// 扫描数值属性 ID：在某一个可见元素上逐个试读，只记录 rc==0 的
static void axScanIds(int idx, int lo, int hi) {
    axActivate();
    AXFront fr = { 0, "" };
    axFrontApp(&fr);
    AXEl app = fr.pid > 0 ? axAppElement(fr.pid) : NULL;
    if (!app) { SBLogSync("AXC no-app"); return; }

    CFTypeRef arr = axCopy(app, (CFStringRef)(uintptr_t)3015);
    long n = (arr && CFGetTypeID(arr) == CFArrayGetTypeID()) ? (long)CFArrayGetCount((CFArrayRef)arr) : -1;
    if (n <= 0) { if (arr) CFRelease(arr); SBLogSync("AXC no-array n=%ld", n); return; }
    if (idx < 0 || idx >= n) idx = 0;

    AXEl el = (AXEl)CFArrayGetValueAtIndex((CFArrayRef)arr, idx);
    SBLogSync("AXC scan idx=%d of %ld range=%d..%d", idx, n, lo, hi);

    int found = 0;
    for (int id = lo; id <= hi; id++) {
        CFTypeRef v = axCopy(el, (CFStringRef)(uintptr_t)id);
        if (!v) continue;
        CFTypeID t = CFGetTypeID(v);
        char b[120];
        b[0] = 0;
        if (t == CFStringGetTypeID()) { axCFStrTo(b, sizeof(b), (CFStringRef)v); }
        else if (t == CFArrayGetTypeID()) snprintf(b, sizeof(b), "[array %ld]", (long)CFArrayGetCount((CFArrayRef)v));
        else if (t == CFNumberGetTypeID() || t == CFBooleanGetTypeID()) axAnyTo(b, sizeof(b), v);
        else if (t == CFDictionaryGetTypeID()) snprintf(b, sizeof(b), "[dict %ld]", (long)CFDictionaryGetCount((CFDictionaryRef)v));
        else if (g_axValueGet) {
            CGRect r; if (axRectGet(v, &r)) snprintf(b, sizeof(b), "rect %g,%g,%g,%g", r.origin.x, r.origin.y, r.size.width, r.size.height);
            else { CGPoint p; if (axPointGet(v, &p)) snprintf(b, sizeof(b), "pt %g,%g", p.x, p.y); else snprintf(b, sizeof(b), "<type %lu>", (unsigned long)t); }
        } else snprintf(b, sizeof(b), "<type %lu>", (unsigned long)t);

        if (b[0]) { SBLogSync("AXC id=%d %s", id, b); found++; }
        CFRelease(v);
    }
    CFRelease(arr);
    SBLogSync("AXC done found=%d", found);
}

// 诊断：符号键本身长什么样（地址/类型/长度/内容），以及拿它在元素上试读的 rc
static void axKeysProbe(int idx) {
    axActivate();
    AXFront fr = { 0, "" };
    axFrontApp(&fr);
    AXEl app = fr.pid > 0 ? axAppElement(fr.pid) : NULL;
    if (!app) { SBLogSync("AXK no-app"); return; }

    CFTypeRef arr = axCopy(app, (CFStringRef)(uintptr_t)3015);
    long n = (arr && CFGetTypeID(arr) == CFArrayGetTypeID()) ? (long)CFArrayGetCount((CFArrayRef)arr) : -1;
    if (n <= 0) { if (arr) CFRelease(arr); SBLogSync("AXK no-array"); return; }
    if (idx < 0 || idx >= n) idx = 0;
    AXEl el = (AXEl)CFArrayGetValueAtIndex((CFArrayRef)arr, idx);
    SBLogSync("AXK idx=%d of %ld", idx, n);

    const char *syms[10] = {
        "kAXXCAttributeLabel", "kAXXCAttributeValue", "kAXXCAttributeElementType",
        "kAXXCAttributeFrame", "kAXXCAttributeVisibleFrame", "kAXXCAttributeIdentifier",
        "kAXXCAttributeTraits", "kAXXCAttributeIsVisible", "kAXXCAttributeIsUserInteractionEnabled",
        "kAXXCAttributeChildren"
    };
    for (int i = 0; i < 10; i++) {
        void *raw = g_axHandle ? dlsym(g_axHandle, syms[i]) : NULL;
        if (!raw) raw = dlsym(RTLD_DEFAULT, syms[i]);
        if (!raw) { SBLogSync("AXK %s MISS", syms[i]); continue; }

        CFStringRef s = *(CFStringRef *)raw;
        char b[96]; b[0] = 0;
        unsigned long tid = 0;
        long len = -1;
        if (s) {
            tid = (unsigned long)CFGetTypeID(s);
            if (tid == (unsigned long)CFStringGetTypeID()) {
                len = (long)CFStringGetLength(s);
                axCFStrTo(b, sizeof(b), s);
            } else {
                snprintf(b, sizeof(b), "<not-string>");
            }
        }
        int rc = -999;
        CFTypeRef v = NULL;
        if (s && g_axCopyAttr) rc = g_axCopyAttr(el, s, &v);
        if (v) CFRelease(v);
        SBLogSync("AXK %s slot=%p str=%p type=%lu len=%ld rc=%d val='%s'", syms[i], raw, s, tid, len, rc, b);
    }
    CFRelease(arr);
}

// 诊断：枚举类方法名里含 needle 的（找前台的入口）
static void axListSelectors(Class cls, const char *tag, const char *needle) {
    if (!cls) { SBLogSync("AXQ cls %s MISS", tag); return; }
    unsigned int cnt = 0;
    Method *ms = class_copyMethodList(cls, &cnt);
    if (!ms) { SBLogSync("AXQ cls %s no-methods", tag); return; }
    int shown = 0;
    for (unsigned int i = 0; i < cnt && shown < 12; i++) {
        const char *n = sel_getName(method_getName(ms[i]));
        if (needle && *needle && !strstr(n, needle)) continue;
        SBLogSync("AXQ %s -%s", tag, n);
        shown++;
    }
    free(ms);
}

static void axFrontProbe(void) {
    const char *classes[8] = {
        "SBApplicationController", "SBApplication", "SBWorkspace", "SBMainWorkspace",
        "SBWorkspaceApplicationSceneHandle", "SBSceneManager", "SBUIController", "SBAppSwitcherController"
    };
    const char *needles[2] = { "front", "active" };
    for (int c = 0; c < 8; c++) {
        Class cls = objc_getClass(classes[c]);
        if (!cls) { SBLogSync("AXQ class %s MISS", classes[c]); continue; }
        for (int n = 0; n < 2; n++) axListSelectors(cls, classes[c], needles[n]);
    }

    // SBApplicationController 的实例方法名与 allApplications 结果
    Class ctrl = objc_getClass("SBApplicationController");
    if (ctrl) {
        id inst = ((id (*)(id, SEL))objc_msgSend)((id)ctrl, sel_registerName("sharedInstance"));
        if (inst) {
            axListSelectors(object_getClass(inst), "SBApplicationController(inst)", "front");
            id all = NULL;
            BOOL canAll = ((BOOL (*)(id, SEL, SEL))objc_msgSend)(inst, sel_registerName("respondsToSelector:"), sel_registerName("allApplications"));
            if (canAll) {
                all = ((id (*)(id, SEL))objc_msgSend)(inst, sel_registerName("allApplications"));
                SBLogSync("AXQ allApplications -> %s", all ? "obj" : "nil");
            } else {
                SBLogSync("AXQ allApplications not-responded");
            }
        } else {
            SBLogSync("AXQ SBApplicationController sharedInstance nil");
        }
    }

    // 逐个 App 问 isFrontmost
    Class appCls = objc_getClass("SBApplication");
    if (appCls) axListSelectors(appCls, "SBApplication", "isFront");
    SBLogSync("AXQ probe done");
}

// 用 SBApplicationController 的 allApplications + isFrontmost 找前台
static int axFrontViaApps(AXFront *out) {
    Class ctl = objc_getClass("SBApplicationController");
    if (!ctl) { SBLogSync("AXR no SBApplicationController"); return 0; }
    id inst = ((id (*)(id, SEL))objc_msgSend)((id)ctl, sel_registerName("sharedInstance"));
    if (!inst) { SBLogSync("AXR sharedInstance nil"); return 0; }

    BOOL canAll = ((BOOL (*)(id, SEL, SEL))objc_msgSend)(inst, sel_registerName("respondsToSelector:"), sel_registerName("allApplications"));
    if (!canAll) { SBLogSync("AXR no allApplications"); return 0; }
    id all = ((id (*)(id, SEL))objc_msgSend)(inst, sel_registerName("allApplications"));
    if (!all) { SBLogSync("AXR allApplications nil"); return 0; }

    unsigned long cnt = ((unsigned long (*)(id, SEL))objc_msgSend)(all, sel_registerName("count"));
    SBLogSync("AXR apps count=%lu", (unsigned long)cnt);

    int found = 0;
    for (unsigned long i = 0; i < cnt && i < 60; i++) {
        id app = ((id (*)(id, SEL, unsigned long))objc_msgSend)(all, sel_registerName("objectAtIndex:"), i);
        if (!app) continue;
        id bundle = ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("bundleIdentifier"));
        char b[128]; b[0] = 0;
        if (bundle) {
            CFStringRef s = (__bridge CFStringRef)bundle;
            axCFStrTo(b, sizeof(b), s);
        }
        int isFront = 0;
        if (((BOOL (*)(id, SEL, SEL))objc_msgSend)(app, sel_registerName("respondsToSelector:"), sel_registerName("isFrontmost")))
            isFront = ((BOOL (*)(id, SEL))objc_msgSend)(app, sel_registerName("isFrontmost")) ? 1 : 0;

        int pid = -1;
        if (((BOOL (*)(id, SEL, SEL))objc_msgSend)(app, sel_registerName("respondsToSelector:"), sel_registerName("pid")))
            pid = (int)((pid_t (*)(id, SEL))objc_msgSend)(app, sel_registerName("pid"));

        if (isFront) {
            SBLogSync("AXR FRONT bundle=%s pid=%d", b, pid);
            if (pid > 0) {
                out->pid = pid;
                snprintf(out->bundle, sizeof(out->bundle), "%s", b);
                found = 1;
            }
        }
    }
    if (!found) SBLogSync("AXR no front flag");
    return found;
}

static void axFrontProbe2(void) {
    AXFront fr = { 0, "" };
    int r = axFrontViaApps(&fr);
    SBLogSync("AXR result=%d pid=%d bundle=%s", r, fr.pid, fr.bundle);
}

// 每个 App 的 processState / sceneState，找非 0 的（前台候选）
static void axAppStates(void) {
    Class ctl = objc_getClass("SBApplicationController");
    id inst = ctl ? ((id (*)(id, SEL))objc_msgSend)((id)ctl, sel_registerName("sharedInstance")) : nil;
    if (!inst) { SBLogSync("AXP2 no controller"); return; }
    id all = ((id (*)(id, SEL))objc_msgSend)(inst, sel_registerName("allApplications"));
    if (!all) { SBLogSync("AXP2 allApplications nil"); return; }
    unsigned long cnt = ((unsigned long (*)(id, SEL))objc_msgSend)(all, sel_registerName("count"));
    SBLogSync("AXP2 count=%lu", cnt);

    int shown = 0;
    for (unsigned long i = 0; i < cnt && shown < 20; i++) {
        id app = ((id (*)(id, SEL, unsigned long))objc_msgSend)(all, sel_registerName("objectAtIndex:"), i);
        if (!app) continue;
        id bundle = ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("bundleIdentifier"));
        char b[128]; b[0] = 0;
        if (bundle) axCFStrTo(b, sizeof(b), (__bridge CFStringRef)bundle);

        int ps = -999, ss = -999, fm = -999;
        BOOL hasPS = ((BOOL (*)(id, SEL, SEL))objc_msgSend)(app, sel_registerName("respondsToSelector:"), sel_registerName("processState"));
        if (hasPS) ps = (int)((long (*)(id, SEL))objc_msgSend)(app, sel_registerName("processState"));
        BOOL hasSS = ((BOOL (*)(id, SEL, SEL))objc_msgSend)(app, sel_registerName("respondsToSelector:"), sel_registerName("sceneState"));
        if (hasSS) ss = (int)((long (*)(id, SEL))objc_msgSend)(app, sel_registerName("sceneState"));
        BOOL hasFM = ((BOOL (*)(id, SEL, SEL))objc_msgSend)(app, sel_registerName("respondsToSelector:"), sel_registerName("isFrontmost"));
        if (hasFM) fm = ((BOOL (*)(id, SEL))objc_msgSend)(app, sel_registerName("isFrontmost")) ? 1 : 0;

        if (ps > 0 || ss > 0 || fm > 0) {
            SBLogSync("AXP2 %s ps=%d ss=%d front=%d hasPS=%d hasSS=%d", b, ps, ss, fm, hasPS ? 1 : 0, hasSS ? 1 : 0);
            shown++;
        }
    }
    // 顺便打 SBApplication 上前台相关选择器是否存在
    Class appCls = objc_getClass("SBApplication");
    if (appCls) {
        const char *sels[6] = { "isFrontmost", "frontmost", "isFrontMostApp", "processState", "sceneState", "displayItem" };
        for (int k = 0; k < 6; k++) {
            SEL sel = sel_registerName(sels[k]);
            SBLogSync("AXP2 sel %s inst=%d", sels[k],
                      ((BOOL (*)(id, SEL, SEL))objc_msgSend)((id)appCls, sel_registerName("instancesRespondToSelector:"), sel) ? 1 : 0);
        }
    }
    SBLogSync("AXP2 done shown=%d", shown);
}

// 实测法：逐个跑着的 App 建元素读 3015，有元素的那个就是真前台
static void axFrontScan(void) {
    Class ctl = objc_getClass("SBApplicationController");
    id inst = ctl ? ((id (*)(id, SEL))objc_msgSend)((id)ctl, sel_registerName("sharedInstance")) : nil;
    if (!inst) { SBLogSync("AXF2 no controller"); return; }
    id all = ((id (*)(id, SEL))objc_msgSend)(inst, sel_registerName("allApplications"));
    if (!all) { SBLogSync("AXF2 allApplications nil"); return; }
    unsigned long cnt = ((unsigned long (*)(id, SEL))objc_msgSend)(all, sel_registerName("count"));
    SBLogSync("AXF2 count=%lu", cnt);

    int tried = 0, found = 0;
    for (unsigned long i = 0; i < cnt && !found; i++) {
        id app = ((id (*)(id, SEL, unsigned long))objc_msgSend)(all, sel_registerName("objectAtIndex:"), i);
        if (!app) continue;
        BOOL hasPid = ((BOOL (*)(id, SEL, SEL))objc_msgSend)(app, sel_registerName("respondsToSelector:"), sel_registerName("pid"));
        if (!hasPid) continue;
        int pid = (int)((pid_t (*)(id, SEL))objc_msgSend)(app, sel_registerName("pid"));
        if (pid <= 0) continue;

        id bundle = ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("bundleIdentifier"));
        char b[128]; b[0] = 0;
        if (bundle) axCFStrTo(b, sizeof(b), (__bridge CFStringRef)bundle);

        tried++;
        AXEl el = axAppElement(pid);
        if (!el) continue;
        CFTypeRef arr = axCopy(el, (CFStringRef)(uintptr_t)3015);
        long n = (arr && CFGetTypeID(arr) == CFArrayGetTypeID()) ? (long)CFArrayGetCount((CFArrayRef)arr) : -1;
        if (arr) CFRelease(arr);
        if (n > 0) {
            SBLogSync("AXF2 FRONT bundle=%s pid=%d n=%ld tried=%d", b, pid, n, tried);
            g_axTargetPid = pid;
            found = 1;
        }
    }
    SBLogSync("AXF2 done found=%d tried=%d", found, tried);
}

// 只回元素数量，供外部逐个 pid 试探前台
static void axCountProbe(void) {
    AXFront fr = { 0, "" };
    int hasFront = axFrontApp(&fr);
    AXEl app = fr.pid > 0 ? axAppElement(fr.pid) : NULL;
    if (!app) { SBLogSync("AXC2 no-app pid=%d", fr.pid); return; }
    CFTypeRef a1 = axCopy(app, (CFStringRef)(uintptr_t)3015);
    CFTypeRef a2 = axCopy(app, (CFStringRef)(uintptr_t)3022);
    long n1 = (a1 && CFGetTypeID(a1) == CFArrayGetTypeID()) ? (long)CFArrayGetCount((CFArrayRef)a1) : -1;
    long n2 = (a2 && CFGetTypeID(a2) == CFArrayGetTypeID()) ? (long)CFArrayGetCount((CFArrayRef)a2) : -1;
    SBLogSync("AXC2 pid=%d front=%d n3015=%ld n3022=%ld", fr.pid, hasFront, n1, n2);
    if (a1) CFRelease(a1);
    if (a2) CFRelease(a2);
}

// ---------- 前台判定：事件流（不查状态） ----------
static char g_frontBundle[160];
static int  g_frontPid;

static void axNoteBundle(id note, const char *why) {
    if (!note) return;
    id obj = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("object"));
    if (!obj) { SBLogSync("AXN3 %s no-object", why); return; }
    id bundle = ((id (*)(id, SEL))objc_msgSend)(obj, sel_registerName("bundleIdentifier"));
    if (!bundle) { SBLogSync("AXN3 %s no-bundle", why); return; }
    char b[160]; b[0] = 0;
    axCFStrTo(b, sizeof(b), (__bridge CFStringRef)bundle);
    snprintf(g_frontBundle, sizeof(g_frontBundle), "%s", b);
    SBLogSync("AXN3 %s bundle=%s", why, g_frontBundle);
}

static void axNoteClear(const char *why) {
    g_frontBundle[0] = 0;
    SBLogSync("AXN3 %s -> cleared", why);
}

static void axSetupFrontNotifications(void) {
    static int done = 0;
    if (done) return;
    done = 1;

    Class ncc = objc_getClass("NSNotificationCenter");
    if (!ncc) { SBLogSync("AXN3 no NSNotificationCenter"); return; }
    id center = ((id (*)(id, SEL))objc_msgSend)((id)ncc, sel_registerName("defaultCenter"));
    if (!center) { SBLogSync("AXN3 defaultCenter nil"); return; }

    void (^onActive)(id) = ^(id note) { axNoteBundle(note, "active"); };
    void (^onResign)(id) = ^(id note) { (void)note; axNoteClear("resign"); };
    void (^onBg)(id)     = ^(id note) { (void)note; axNoteClear("background"); };

    struct { const char *name; void (^blk)(id); } regs[3] = {
        { "SBApplicationDidBecomeActiveNotification", onActive },
        { "SBApplicationWillResignActiveNotification", onResign },
        { "SBApplicationDidEnterBackgroundNotification", onBg },
    };
    for (int i = 0; i < 3; i++) {
        id nm = SBStr(regs[i].name);
        if (!nm) continue;
        id tok = ((id (*)(id, SEL, id, id, id, id))objc_msgSend)(
            center, sel_registerName("addObserverForName:object:queue:usingBlock:"),
            nm, nil, nil, (__bridge id)regs[i].blk);
        SBLogSync("AXN3 observer %s -> %s", regs[i].name, tok ? "ok" : "nil");
    }
}

// ---------- 属性矩阵：OK / EMPTY / ERR(code) ----------
static void axMatrixOne(AXEl el, const char *tag, CFStringRef key, const char *kname) {
    CFTypeRef v = NULL;
    int rc = (el && key && g_axCopyAttr) ? g_axCopyAttr(el, key, &v) : -999;
    char b[200]; b[0] = 0;
    const char *state = "ERR";
    if (rc == 0) {
        if (!v) state = "EMPTY";
        else {
            CFTypeID t = CFGetTypeID(v);
            if (t == CFStringGetTypeID()) {
                long len = (long)CFStringGetLength((CFStringRef)v);
                axCFStrTo(b, sizeof(b), (CFStringRef)v);
                state = len > 0 ? "OK" : "EMPTY";
            } else if (t == CFArrayGetTypeID()) {
                snprintf(b, sizeof(b), "[array %ld]", (long)CFArrayGetCount((CFArrayRef)v));
                state = "OK";
            } else if (t == CFNumberGetTypeID() || t == CFBooleanGetTypeID()) {
                axAnyTo(b, sizeof(b), v);
                state = "OK";
            } else {
                snprintf(b, sizeof(b), "<type %lu>", (unsigned long)t);
                state = "OK";
            }
            CFRelease(v);
        }
    }
    SBLogSync("AXM %s %s state=%s rc=%d val='%s'", tag, kname, state, rc, b);
}

static void axMatrix(int pid) {
    axActivate();
    if (pid <= 0) { AXFront fr = { 0, "" }; axFrontApp(&fr); pid = fr.pid; }
    AXEl app = pid > 0 ? axAppElement(pid) : NULL;
    if (!app) { SBLogSync("AXM no-app pid=%d", pid); return; }
    SBLogSync("AXM pid=%d front-name=%s", pid, g_frontBundle);

    const char *names[4] = { "AXRole", "AXLabel", "AXValue", "AXFrontmost" };
    for (int i = 0; i < 4; i++) axMatrixOne(app, "app", (__bridge CFStringRef)SBStr(names[i]), names[i]);
    axMatrixOne(app, "app", (CFStringRef)(uintptr_t)2001, "id2001");
    axMatrixOne(app, "app", (CFStringRef)(uintptr_t)2006, "id2006");

    CFTypeRef arr = axCopy(app, (CFStringRef)(uintptr_t)3015);
    long n = (arr && CFGetTypeID(arr) == CFArrayGetTypeID()) ? (long)CFArrayGetCount((CFArrayRef)arr) : -1;
    SBLogSync("AXM visible n=%ld", n);
    if (n > 0) {
        AXEl el = (AXEl)CFArrayGetValueAtIndex((CFArrayRef)arr, 1 < n ? 1 : 0);
        for (int i = 0; i < 4; i++) axMatrixOne(el, "el", (__bridge CFStringRef)SBStr(names[i]), names[i]);
        axMatrixOne(el, "el", (CFStringRef)(uintptr_t)2001, "id2001");
        axMatrixOne(el, "el", (CFStringRef)(uintptr_t)2006, "id2006");
    }
    if (arr) CFRelease(arr);
    SBLogSync("AXM done pid=%d", pid);
}

static void axSymScan(void) {
    const char *want[6] = {
        "__AXSetRequestingClient",
        "_AXOverrideRequestingClientType",
        "_AXUIElementCreateAppElementWithPid",
        "_AXAddAssociatedPid",
        "AXFrontBoardFocusedAppPID",
        "AXUIElementCopyAttributeNames"
    };
    int cnt = _dyld_image_count();
    SBLogSync("SYMX images=%d", cnt);
    int probed = 0, hits = 0;
    for (int i = 0; i < cnt; i++) {
        const char *path = _dyld_get_image_name(i);
        if (!path) continue;
        const char *base = strrchr(path, '/');
        base = base ? base + 1 : path;
        if (!strstr(base, "Accessibility") && !strstr(base, "AX") &&
            !strstr(base, "UIKitCore") && !strstr(base, "BackBoard") &&
            !strstr(base, "SpringBoard") && !strstr(base, "Accessibility"))
            continue;
        probed++;
        SBLogSync("SYMX img %s", base);
        void *h = dlopen(path, RTLD_LAZY);
        if (!h) { SBLogSync("SYMX dlopen fail %s", base); continue; }
        for (int k = 0; k < 6; k++) {
            void *p = dlsym(h, want[k]);
            if (p) { hits++; SBLogSync("SYMX HIT %s -> %s addr=%p", want[k], base, p); }
        }
    }
    SBLogSync("SYMX done probed=%d hits=%d", probed, hits);
}

static int axCaseEq(const char *a, const char *b) {
    if (!a || !b) return 0;
    while (*a && *b) {
        char ca = *a, cb = *b;
        if (ca >= 'A' && ca <= 'Z') ca += 32;
        if (cb >= 'A' && cb <= 'Z') cb += 32;
        if (ca != cb) return 0;
        a++; b++;
    }
    return (*a == 0 && *b == 0);
}

static int axCaseContains(const char *hay, const char *needle) {
    if (!hay || !needle || !needle[0]) return 0;
    size_t n = strlen(needle);
    for (const char *p = hay; *p; p++) {
        size_t i = 0;
        while (i < n && p[i]) {
            char ca = p[i], cb = needle[i];
            if (ca >= 'A' && ca <= 'Z') ca += 32;
            if (cb >= 'A' && cb <= 'Z') cb += 32;
            if (ca != cb) break;
            i++;
        }
        if (i == n) return 1;
    }
    return 0;
}

// 按进程名 / bundle 末段 / 中文别名反查 pid（只读内核进程表，不碰 AX）
static void axPidOf(const char *q) {
    if (!q || !q[0]) { SBLogSync("AXP pidof empty"); return; }

    // 常见中文名 → 进程名（后续可扩表）
    static const char *al[][2] = {
        { "设置", "Preferences" }, { "天气", "Weather" }, { "电话", "MobilePhone" },
        { "信息", "MobileSMS" }, { "相册", "MobileSlideShow" }, { "时钟", "MobileTimer" },
        { "相机", "Camera" }, { "日历", "MobileCal" }, { "备忘录", "MobileNotes" },
        { "地图", "Maps" }, { "邮件", "MobileMail" }, { "音乐", "Music" },
        { "微信", "WeChat" }, { "抖音", "Aweme" }, { "Safari", "MobileSafari" }
    };
    const char *want = q;
    for (size_t i = 0; i < sizeof(al) / sizeof(al[0]); i++) {
        if (!strcmp(q, al[i][1 - 1])) { want = al[i][1]; break; }
    }
    // bundle id 取最后一段：com.apple.Preferences → Preferences
    if (strchr(want, '.')) {
        const char *dot = strrchr(want, '.');
        if (dot && dot[1]) want = dot + 1;
    }

    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t sz = 0;
    if (sysctl(mib, 4, NULL, &sz, NULL, 0) != 0 || sz == 0) {
        SBLogSync("AXP pidof sysctl-size fail q=%s", want);
        return;
    }
    sz += 4096;
    char *buf = (char *)malloc(sz);
    if (!buf) return;
    if (sysctl(mib, 4, buf, &sz, NULL, 0) != 0) {
        SBLogSync("AXP pidof sysctl fail q=%s", want);
        free(buf);
        return;
    }

    int n = (int)(sz / sizeof(struct kinfo_proc));
    int hits = 0;
    struct kinfo_proc *kp = (struct kinfo_proc *)buf;
    for (int i = 0; i < n; i++) {
        const char *comm = kp[i].kp_proc.p_comm;
        if (!comm || !comm[0]) continue;
        if (!axCaseEq(comm, want) && !axCaseContains(comm, want)) continue;
        SBLogSync("AXP hit pid=%d comm=%s", kp[i].kp_proc.p_pid, comm);
        hits++;
        if (hits >= 6) break;
    }
    SBLogSync("AXP pidof q=%s n=%d hits=%d", want, n, hits);
    free(buf);
}

// 名字 → pid（精确优先；返回 0 表示未知，调用方不得猜）
static int axPidByQuery(const char *q, char *commOut, size_t cap) {
    if (!q || !q[0]) return 0;
    static const char *al[][2] = {
        { "设置", "Preferences" }, { "天气", "Weather" }, { "电话", "MobilePhone" },
        { "信息", "MobileSMS" }, { "相册", "MobileSlideShow" }, { "时钟", "MobileTimer" },
        { "相机", "Camera" }, { "日历", "MobileCal" }, { "备忘录", "MobileNotes" },
        { "地图", "Maps" }, { "邮件", "MobileMail" }, { "音乐", "Music" },
        { "微信", "WeChat" }, { "抖音", "Aweme" }, { "Safari", "MobileSafari" }
    };
    const char *want = q;
    for (size_t i = 0; i < sizeof(al) / sizeof(al[0]); i++) {
        if (!strcmp(q, al[i][0])) { want = al[i][1]; break; }
    }
    if (strchr(want, '.')) {
        const char *dot = strrchr(want, '.');
        if (dot && dot[1]) want = dot + 1;
    }

    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t sz = 0;
    if (sysctl(mib, 4, NULL, &sz, NULL, 0) != 0 || sz == 0) return 0;
    sz += 4096;
    char *buf = (char *)malloc(sz);
    if (!buf) return 0;
    if (sysctl(mib, 4, buf, &sz, NULL, 0) != 0) { free(buf); return 0; }

    int n = (int)(sz / sizeof(struct kinfo_proc));
    int best = 0, bestScore = 0;
    char bestComm[64] = { 0 };
    struct kinfo_proc *kp = (struct kinfo_proc *)buf;
    for (int i = 0; i < n; i++) {
        const char *comm = kp[i].kp_proc.p_comm;
        if (!comm || !comm[0]) continue;
        int score = 0;
        if (axCaseEq(comm, want)) score = 2;
        else if (axCaseContains(comm, want)) score = 1;
        if (score > bestScore) {
            bestScore = score;
            best = kp[i].kp_proc.p_pid;
            snprintf(bestComm, sizeof(bestComm), "%s", comm);
        }
    }
    free(buf);
    if (commOut && cap) snprintf(commOut, cap, "%s", bestComm);
    return best;
}

// ------------------------------------------------------------------ 坐标命中 → pid（frontchain 第一级）
// 不依赖任何“谁是前台”的查询：给屏幕点，让 AX 返回该点元素，再取元素的 pid
static void axHitPid(float x, float y) {
    char lab[160] = { 0 };
    int pid = 0;
    axActivate();
    if (!g_axSysCreate) { SBLogSync("AXH no sysCreate"); return; }
    if (!g_axHitTest)    { SBLogSync("AXH no hitTest"); return; }

    AXEl sw = NULL;
    @try { sw = g_axSysCreate(); } @catch (NSException *e) { (void)e; sw = NULL; }
    if (!sw) { SBLogSync("AXH syswide nil"); return; }
    if (g_axTimeout) g_axTimeout(sw, 0.5f);

    AXEl el = NULL;
    int rc = -999;
    @try { rc = g_axHitTest(sw, x, y, &el); }
    @catch (NSException *e) { (void)e; rc = -999; }
    SBLogSync("AXH hit xy=%.0f,%.0f rc=%d el=%p", x, y, rc, el);

    if (rc == 0 && el) {
        if (g_axGetPid) {
            @try { g_axGetPid(el, &pid); } @catch (NSException *e) { (void)e; pid = 0; }
        }
        // 命中到自己 = 主屏/SpringBoard 自身。绝不能对自身元素读属性（会自锁），只取 pid
        if (pid == (int)getpid()) {
            SBLogSync("AXH home xy=%.0f,%.0f pid=%d (self, skip attr read)", x, y, pid);
        } else if (g_axCopyAttr) {
            CFTypeRef v = axCopy(el, (CFStringRef)(uintptr_t)2001);
            if (!v) v = axCopy(el, (CFStringRef)(uintptr_t)2006);
            if (v) {
                if (CFGetTypeID(v) == CFStringGetTypeID()) axCFStrTo(lab, sizeof(lab), (CFStringRef)v);
                CFRelease(v);
            }
        }
        SBLogSync("AXH pid=%d label='%s'", pid, lab);
        CFRelease(el);
    } else if (el) {
        CFRelease(el);
    }
    CFRelease(sw);

    // 供上层机器读取：命中结果落盘（失败也要落，带明确 rc）
    FILE *f = fopen(AX_HIT_FILE, "w");
    if (f) {
        fprintf(f, "{\"ok\":%d,\"mode\":\"hit\",\"x\":%.1f,\"y\":%.1f,\"rc\":%d,\"pid\":%d,\"state\":\"%s\",\"label\":",
                (rc == 0 ? 1 : 0), x, y, rc, pid,
                (rc == 0 && pid > 0) ? (pid == (int)getpid() ? "home" : "app") : "unresolved");
        fputs("\"", f);
        for (const char *p = lab; *p; p++) {
            if (*p == '"' || *p == '\\') { fputc('\\', f); fputc(*p, f); }
            else if (*p == '\n') { fputs("\\n", f); }
            else if ((unsigned char)*p >= 0x20) fputc(*p, f);
        }
        fputs("\"}\n", f);
        fclose(f);
    }
}

// ------------------------------------------------------------------ act：名字/pid + 文案 → 点击 → 验证
// 严格四态：no-pid / no-element / not-found / multiple / ok + changed
static int axOnScreenPid(int rcOut[3]);

static void axAct(const char *target, const char *label) {
    char comm[64] = { 0 };
    int pid = 0;
    int byPid = 1;
    for (const char *p = target; *p; p++) if (*p < '0' || *p > '9') { byPid = 0; break; }
    if (byPid) pid = atoi(target);
    else pid = axPidByQuery(target, comm, sizeof(comm));

    SBLogSync("ACT start target=%s label='%s' pid=%d comm=%s", target, label, pid, comm);
    if (pid <= 0) {
        SBLogSync("ACT fail reason=no-pid target=%s", target);
        FILE *f = fopen(AX_ACT_FILE, "w");
        if (f) { fprintf(f, "{\"ok\":0,\"reason\":\"no-pid\",\"target\":\"%s\"}\n", target); fclose(f); }
        return;
    }

    axActivate();

    // 前置：这个 App 是不是真的在屏幕上。不在屏幕上点下去只会白点，且"没反应"无法与"点错"区分。
    if (g_axSkipFrontCheck == 0) {
        int rcs[3];
        int onp = axOnScreenPid(rcs);
        if (onp != pid) {
            SBLogSync("ACT fail reason=not-front pid=%d onscreen=%d rc=%d,%d,%d", pid, onp, rcs[0], rcs[1], rcs[2]);
            FILE *ff = fopen(AX_ACT_FILE, "w");
            if (ff) {
                fprintf(ff, "{\"ok\":0,\"reason\":\"not-front\",\"pid\":%d,\"onscreen\":%d,\"home\":%d}\n",
                        pid, onp, onp ? 0 : 1);
                fclose(ff);
            }
            return;
        }
    }

    g_axTargetPid = pid;
    AXEl app = axAppElement(pid);
    if (!app) {
        SBLogSync("ACT fail reason=no-element pid=%d", pid);
        FILE *f = fopen(AX_ACT_FILE, "w");
        if (f) { fprintf(f, "{\"ok\":0,\"reason\":\"no-element\",\"pid\":%d}\n", pid); fclose(f); }
        return;
    }

    int n0 = 0, h0 = 0, matches = 0, extra = 0;
    CGPoint first = CGPointZero;
    CGPoint others[4]; memset(others, 0, sizeof(others));

    CFTypeRef arr = axCopy(app, (CFStringRef)(uintptr_t)3015);
    long n = (arr && CFGetTypeID(arr) == CFArrayGetTypeID()) ? (long)CFArrayGetCount((CFArrayRef)arr) : -1;
    for (long i = 0; i < n; i++) {
        AXEl el = (AXEl)CFArrayGetValueAtIndex((CFArrayRef)arr, i);
        if (!el) continue;
        char lbl[200]; axLabelOf(el, lbl, sizeof(lbl));
        n0++; h0 += (int)strlen(lbl);
        if (!lbl[0] || !label || !label[0]) continue;
        if (!strstr(lbl, label)) continue;

        CGPoint ctr = CGPointZero;
        CFTypeRef cp = axCopy(el, (CFStringRef)(uintptr_t)2007);
        if (cp) { axPointGet(cp, &ctr); CFRelease(cp); }
        matches++;
        if (matches == 1) first = ctr;
        else if (extra < 4) { others[extra++] = ctr; }
    }
    if (arr) CFRelease(arr);

    if (matches == 0) {
        // 区分“界面里没这个词”和“这个 App 根本没有活跃树”，两者可处置方式不同
        const char *reason = (n0 > 0) ? "not-found" : "no-tree";
        SBLogSync("ACT fail reason=%s pid=%d n=%d label='%s'", reason, pid, n0, label);
        FILE *f = fopen(AX_ACT_FILE, "w");
        if (f) { fprintf(f, "{\"ok\":0,\"reason\":\"%s\",\"pid\":%d,\"count\":%d}\n", reason, pid, n0); fclose(f); }
        return;
    }
    if (matches > 1) {
        SBLogSync("ACT fail reason=multiple pid=%d label='%s' matches=%d", pid, label, matches);
        for (int i = 0; i < extra; i++)
            SBLogSync("ACT candidate center=%g,%g", others[i].x, others[i].y);
        FILE *f = fopen(AX_ACT_FILE, "w");
        if (f) {
            fprintf(f, "{\"ok\":0,\"reason\":\"multiple\",\"pid\":%d,\"matches\":%d,\"cands\":[", pid, matches);
            fprintf(f, "[%.1f,%.1f]", first.x, first.y);
            for (int i = 0; i < extra; i++) fprintf(f, ",[%.1f,%.1f]", others[i].x, others[i].y);
            fprintf(f, "]}\n");
            fclose(f);
        }
        return;
    }

    int tap = SBTouchTap(first.x, first.y);
    SBLogSync("ACT tap pid=%d label='%s' at=%g,%g rc=%d", pid, label, first.x, first.y, tap);
    usleep(1200000);

    int n1 = 0, h1 = 0;
    CFTypeRef arr2 = axCopy(app, (CFStringRef)(uintptr_t)3015);
    long n2 = (arr2 && CFGetTypeID(arr2) == CFArrayGetTypeID()) ? (long)CFArrayGetCount((CFArrayRef)arr2) : -1;
    for (long i = 0; i < n2; i++) {
        AXEl el = (AXEl)CFArrayGetValueAtIndex((CFArrayRef)arr2, i);
        if (!el) continue;
        char lbl[200]; axLabelOf(el, lbl, sizeof(lbl));
        n1++; h1 += (int)strlen(lbl);
    }
    if (arr2) CFRelease(arr2);

    int changed = (n0 != n1 || h0 != h1) ? 1 : 0;
    SBLogSync("ACT result pid=%d label='%s' tap=%d changed=%d before=%d/%d after=%d/%d",
              pid, label, tap, changed, n0, h0, n1, h1);

    FILE *f = fopen(AX_ACT_FILE, "w");
    if (f) {
        fprintf(f, "{\"ok\":%d,\"reason\":\"%s\",\"pid\":%d,\"label\":", changed ? 1 : 0, changed ? "confirmed" : "unconfirmed", pid);
        fputs("\"", f);
        for (const char *p = label; *p; p++) {
            if (*p == '"' || *p == '\\') { fputc('\\', f); fputc(*p, f); }
            else if ((unsigned char)*p >= 0x20) fputc(*p, f);
        }
        fputs("\"", f);
        fprintf(f, ",\"x\":%.1f,\"y\":%.1f,\"tap\":%d,\"before\":{\"n\":%d},\"after\":{\"n\":%d}}\n",
                first.x, first.y, tap, n0, n1);
        fclose(f);
    }
}

// ------------------------------------------------------------------ 阶段4：元素定位 DSL
// spec 用 & 串条件，全部满足才命中：label=子串 / traits=子串 / idx=N / region=x1,y1,x2,y2
// 例：label=无线&region=0,300,430,500　　traits=button&idx=2
typedef struct {
    char label[96]; int hasLabel;
    char traits[48]; int hasTraits;
    int idx;
    int hasRegion; float rx1, ry1, rx2, ry2;
    int pick;   // 0=默认(多条即报 multiple) 1=area(取面积最大) 2=first 3=last
} AxQ;

typedef struct {
    int n0, h0, count;
    int idx[12];
    char lbl[12][120];
    char tr[12][64];
    CGRect fr[12];
    CGPoint ct[12];
} AxQRes;

static int axQParse(const char *spec, AxQ *q) {
    memset(q, 0, sizeof(*q));
    q->idx = -1;
    char buf[220];
    snprintf(buf, sizeof(buf), "%s", spec);

    char *p = buf;
    while (p && *p) {
        char *amp = strchr(p, '&');
        if (amp) *amp = 0;
        char *eq = strchr(p, '=');
        if (!eq) return 0;
        *eq = 0;
        char *k = p, *v = eq + 1;
        if (!strncmp(k, "label", 5)) { snprintf(q->label, sizeof(q->label), "%s", v); q->hasLabel = 1; }
        else if (!strncmp(k, "traits", 6)) { snprintf(q->traits, sizeof(q->traits), "%s", v); q->hasTraits = 1; }
        else if (!strncmp(k, "idx", 3)) q->idx = atoi(v);
        else if (!strncmp(k, "region", 6)) {
            q->hasRegion = 1;
            sscanf(v, "%f,%f,%f,%f", &q->rx1, &q->ry1, &q->rx2, &q->ry2);
        } else if (!strncmp(k, "pick", 4)) {
            if (!strcmp(v, "area")) q->pick = 1;
            else if (!strcmp(v, "first")) q->pick = 2;
            else if (!strcmp(v, "last")) q->pick = 3;
            else return 0;
        } else return 0;
        p = amp ? amp + 1 : NULL;
    }
    return 1;
}

static int axQMatch(const AxQ *q, int i, const char *lbl, const char *tr, CGPoint c) {
    if (q->hasLabel && !axCaseContains(lbl, q->label)) return 0;
    if (q->hasTraits && !axCaseContains(tr, q->traits)) return 0;
    if (q->idx >= 0 && i != q->idx) return 0;
    if (q->hasRegion && !(c.x >= q->rx1 && c.x <= q->rx2 && c.y >= q->ry1 && c.y <= q->ry2)) return 0;
    return 1;
}

static int axQCollect(AXEl app, const AxQ *q, AxQRes *r) {
    memset(r, 0, sizeof(*r));
    CFTypeRef arr = axCopy(app, (CFStringRef)(uintptr_t)3015);
    long n = (arr && CFGetTypeID(arr) == CFArrayGetTypeID()) ? (long)CFArrayGetCount((CFArrayRef)arr) : -1;

    for (long i = 0; i < n; i++) {
        AXEl el = (AXEl)CFArrayGetValueAtIndex((CFArrayRef)arr, i);
        if (!el) continue;
        char lbl[120]; axLabelOf(el, lbl, sizeof(lbl));
        r->n0++; r->h0 += (int)strlen(lbl);

        char tr[64] = { 0 };
        if (q->hasTraits) {
            CFTypeRef tv = axCopy(el, (CFStringRef)(uintptr_t)2041);
            if (tv) { axAnyTo(tr, sizeof(tr), tv); CFRelease(tv); }
        }
        CGPoint ct = CGPointZero;
        CFTypeRef cp = axCopy(el, (CFStringRef)(uintptr_t)2007);
        if (cp) { axPointGet(cp, &ct); CFRelease(cp); }

        if (!axQMatch(q, (int)i, lbl, tr, ct)) continue;
        if (r->count >= 12) continue;

        int k = r->count++;
        r->idx[k] = (int)i;
        snprintf(r->lbl[k], sizeof(r->lbl[k]), "%s", lbl);
        snprintf(r->tr[k], sizeof(r->tr[k]), "%s", tr);
        r->ct[k] = ct;
        CFTypeRef frv = axCopy(el, (CFStringRef)(uintptr_t)2057);
        if (frv) { axRectGet(frv, &r->fr[k]); CFRelease(frv); }
    }
    if (arr) CFRelease(arr);
    return r->count;
}

static int axQTargetPid(const char *target, char *comm, size_t cap) {
    int byPid = 1;
    for (const char *p = target; *p; p++) if (*p < '0' || *p > '9') { byPid = 0; break; }
    return byPid ? atoi(target) : axPidByQuery(target, comm, cap);
}

static void axQWriteItems(FILE *f, const AxQRes *r, int upto) {
    for (int k = 0; k < upto && k < r->count; k++) {
        char jl[300], jt[120];
        axEsc(jl, sizeof(jl), r->lbl[k]);
        axEsc(jt, sizeof(jt), r->tr[k]);
        fprintf(f, "%s{\"i\":%d,\"label\":\"%s\",\"traits\":\"%s\",\"frame\":[%.1f,%.1f,%.1f,%.1f],\"center\":[%.1f,%.1f]}",
                k ? "," : "", r->idx[k], jl, jt,
                r->fr[k].origin.x, r->fr[k].origin.y, r->fr[k].size.width, r->fr[k].size.height,
                r->ct[k].x, r->ct[k].y);
    }
}

// doTap=0：只查（findq）；doTap=1：唯一命中就点并自证（tapq）
static void axQuery(const char *target, const char *spec, int doTap) {
    AxQ q;
    const char *path = doTap ? AX_ACT_FILE : AX_QUERY_FILE;
    const char *mode = doTap ? "tapq" : "findq";

    if (!axQParse(spec, &q)) {
        SBLogSync("FQ fail reason=bad-spec '%s'", spec);
        FILE *f = fopen(path, "w");
        if (f) { fprintf(f, "{\"ok\":0,\"mode\":\"%s\",\"reason\":\"bad-spec\",\"spec\":\"%s\"}\n", mode, spec); fclose(f); }
        return;
    }

    char comm[64] = { 0 };
    int pid = axQTargetPid(target, comm, sizeof(comm));
    SBLogSync("FQ start mode=%s target=%s pid=%d spec='%s'", mode, target, pid, spec);
    if (pid <= 0) {
        SBLogSync("FQ fail reason=no-pid target=%s", target);
        FILE *f = fopen(path, "w");
        if (f) { fprintf(f, "{\"ok\":0,\"mode\":\"%s\",\"reason\":\"no-pid\",\"target\":\"%s\"}\n", mode, target); fclose(f); }
        return;
    }

    axActivate();
    AXEl app = axAppElement(pid);
    if (!app) {
        SBLogSync("FQ fail reason=no-element pid=%d", pid);
        FILE *f = fopen(path, "w");
        if (f) { fprintf(f, "{\"ok\":0,\"mode\":\"%s\",\"reason\":\"no-element\",\"pid\":%d}\n", mode, pid); fclose(f); }
        return;
    }

    AxQRes r;
    axQCollect(app, &q, &r);
    SBLogSync("FQ collect pid=%d n=%d h=%d hits=%d", pid, r.n0, r.h0, r.count);
    for (int k = 0; k < r.count; k++)
        SBLogSync("FQ hit i=%d label='%s' traits='%s' center=%g,%g", r.idx[k], r.lbl[k], r.tr[k], r.ct[k].x, r.ct[k].y);

    if (!doTap) {
        FILE *f = fopen(AX_QUERY_FILE, "w");
        if (f) {
            fprintf(f, "{\"ok\":1,\"mode\":\"findq\",\"pid\":%d,\"spec\":\"%s\",\"total\":%d,\"count\":%d,\"items\":[",
                    pid, spec, r.n0, r.count);
            axQWriteItems(f, &r, r.count);
            fprintf(f, "]}\n");
            fclose(f);
        }
        CFRelease(app);
        return;
    }

    // tapq
    const char *reason = NULL;
    if (r.count == 0) reason = (r.n0 > 0) ? "not-found" : "no-tree";

    int rcs[3];
    if (!reason && !g_axSkipFrontCheck) {
        int onp = axOnScreenPid(rcs);
        if (onp != pid) reason = "not-front";
    }

    // 选点：pick=area 取 frame 面积最大，first/last 取首末，未指定则多条即 multiple（不猜）
    int sel = 0;
    if (!reason && r.count > 1 && q.pick) {
        if (q.pick == 1) {
            float best = -1;
            for (int k = 0; k < r.count; k++) {
                float a = r.fr[k].size.width * r.fr[k].size.height;
                if (a > best) { best = a; sel = k; }
            }
        } else if (q.pick == 3) {
            sel = r.count - 1;
        }
        SBLogSync("FQ pick mode=%d sel=%d label='%s'", q.pick, sel, r.lbl[sel]);
    }
    if (!reason && r.count > 1 && !q.pick) reason = "multiple";

    if (reason) {
        SBLogSync("FQ fail reason=%s pid=%d spec='%s' hits=%d", reason, pid, spec, r.count);
        FILE *f = fopen(AX_ACT_FILE, "w");
        if (f) {
            fprintf(f, "{\"ok\":0,\"mode\":\"tapq\",\"reason\":\"%s\",\"pid\":%d,\"spec\":\"%s\",\"count\":%d,\"items\":[",
                    reason, pid, spec, r.count);
            axQWriteItems(f, &r, r.count);
            fprintf(f, "]}\n");
            fclose(f);
        }
        CFRelease(app);
        return;
    }

    CGPoint pt = r.ct[sel];
    int tap = SBTouchTap(pt.x, pt.y);
    SBLogSync("FQ tap pid=%d spec='%s' sel=%d at=%g,%g rc=%d", pid, spec, sel, pt.x, pt.y, tap);
    usleep(1200000);

    int n1 = 0, h1 = 0;
    CFTypeRef arr2 = axCopy(app, (CFStringRef)(uintptr_t)3015);
    long n2 = (arr2 && CFGetTypeID(arr2) == CFArrayGetTypeID()) ? (long)CFArrayGetCount((CFArrayRef)arr2) : -1;
    for (long i = 0; i < n2; i++) {
        AXEl el = (AXEl)CFArrayGetValueAtIndex((CFArrayRef)arr2, i);
        if (!el) continue;
        char lbl[200]; axLabelOf(el, lbl, sizeof(lbl));
        n1++; h1 += (int)strlen(lbl);
    }
    if (arr2) CFRelease(arr2);

    int changed = (r.n0 != n1 || r.h0 != h1) ? 1 : 0;
    SBLogSync("FQ result pid=%d spec='%s' tap=%d changed=%d before=%d/%d after=%d/%d",
              pid, spec, tap, changed, r.n0, r.h0, n1, h1);

    FILE *f = fopen(AX_ACT_FILE, "w");
    if (f) {
        char js[240];
        axEsc(js, sizeof(js), spec);
        fprintf(f, "{\"ok\":%d,\"mode\":\"tapq\",\"reason\":\"%s\",\"pid\":%d,\"spec\":\"%s\",\"tap\":%d,\"x\":%.1f,\"y\":%.1f,\"before\":{\"n\":%d,\"h\":%d},\"after\":{\"n\":%d,\"h\":%d},\"items\":[",
                changed ? 1 : 0, changed ? "confirmed" : "unconfirmed", pid, js, tap, pt.x, pt.y, r.n0, r.h0, n1, h1);
        axQWriteItems(f, &r, sel + 1);
        fprintf(f, "]}\n");
        fclose(f);
    }
    CFRelease(app);
}

// ------------------------------------------------------------------ openapp：启动 + 5 秒确认（判据用“有没有界面树”，不用“是不是前台”）
static int axBundleForName(const char *q, char *out, size_t cap, const char **nameOut) {
    static const char *al[][3] = {
        { "设置", "Preferences", "com.apple.Preferences" },
        { "天气", "Weather", "com.apple.weather" },
        { "电话", "MobilePhone", "com.apple.mobilephone" },
        { "信息", "MobileSMS", "com.apple.MobileSMS" },
        { "相册", "MobileSlideShow", "com.apple.mobileslideshow" },
        { "时钟", "MobileTimer", "com.apple.mobiletimer" },
        { "相机", "Camera", "com.apple.camera" },
        { "日历", "MobileCal", "com.apple.mobilecal" },
        { "备忘录", "MobileNotes", "com.apple.mobilenotes" },
        { "地图", "Maps", "com.apple.Maps" },
        { "邮件", "MobileMail", "com.apple.mobilemail" },
        { "音乐", "Music", "com.apple.Music" },
        { "微信", "WeChat", "com.tencent.xin" },
        { "抖音", "Aweme", "com.ss.iphone.ugc.Aweme" },
        { "Safari", "MobileSafari", "com.apple.mobilesafari" }
    };
    for (size_t i = 0; i < sizeof(al) / sizeof(al[0]); i++) {
        if (!strcmp(q, al[i][0]) || !strcmp(q, al[i][2])) {
            snprintf(out, cap, "%s", al[i][2]);
            if (nameOut) *nameOut = al[i][1];
            return 1;
        }
    }
    if (strchr(q, '.')) { snprintf(out, cap, "%s", q); if (nameOut) *nameOut = NULL; return 1; }
    snprintf(out, cap, "%s", q);
    if (nameOut) *nameOut = q;
    return 0;
}

static void axOpenApp(const char *target) {
    char bundle[160] = { 0 };
    const char *procName = target;
    axBundleForName(target, bundle, sizeof(bundle), &procName);
    if (!procName) procName = target;

    SBLogSync("OPEN start target=%s bundle=%s proc=%s", target, bundle, procName);

    Class lsw = objc_getClass("LSApplicationWorkspace");
    if (!lsw) { SBLogSync("OPEN fail reason=no-api"); return; }
    id ws = ((id (*)(id, SEL))objc_msgSend)((id)lsw, sel_registerName("defaultWorkspace"));
    if (!ws || !((BOOL (*)(id, SEL, SEL))objc_msgSend)(ws, sel_registerName("respondsToSelector:"),
                                                      sel_registerName("openApplicationWithBundleID:"))) {
        SBLogSync("OPEN fail reason=no-api (defaultWorkspace=%p)", ws);
        return;
    }

    id bid = SBStr(bundle);
    BOOL accepted = ((BOOL (*)(id, SEL, id))objc_msgSend)(ws, sel_registerName("openApplicationWithBundleID:"), bid);
    SBLogSync("OPEN request bundle=%s accepted=%d", bundle, accepted ? 1 : 0);

    FILE *f = fopen(AX_LAUNCH_FILE, "w");
    if (!accepted) {
        SBLogSync("OPEN fail reason=launch-rejected bundle=%s", bundle);
        if (f) { fprintf(f, "{\"ok\":0,\"reason\":\"launch-rejected\",\"bundle\":\"%s\"}\n", bundle); fclose(f); }
        return;
    }

    // 5 秒硬限：每秒判一次“这个 App 有没有界面树”（不判前台）
    int pid = 0, n = 0;
    int confirmed = 0;
    for (int i = 1; i <= 5; i++) {
        usleep(1000000);
        pid = axPidByQuery(procName, NULL, 0);
        if (pid <= 0) continue;
        AXEl app = axAppElement(pid);
        if (!app) continue;
        CFTypeRef arr = axCopy(app, (CFStringRef)(uintptr_t)3015);
        long cn = (arr && CFGetTypeID(arr) == CFArrayGetTypeID()) ? (long)CFArrayGetCount((CFArrayRef)arr) : -1;
        if (arr) CFRelease(arr);
        n = (int)cn;
        SBLogSync("OPEN poll t=%ds pid=%d n=%d", i, pid, n);
        if (cn > 0) { confirmed = 1; g_axTargetPid = pid; break; }
    }

    if (confirmed) {
        SBLogSync("OPEN result bundle=%s pid=%d state=launched-confirmed n=%d", bundle, pid, n);
        if (f) { fprintf(f, "{\"ok\":1,\"reason\":\"launched-confirmed\",\"bundle\":\"%s\",\"pid\":%d,\"count\":%d}\n", bundle, pid, n); fclose(f); }
    } else {
        SBLogSync("OPEN result bundle=%s pid=%d state=launched-unconfirmed n=%d", bundle, pid, n);
        if (f) { fprintf(f, "{\"ok\":0,\"reason\":\"launched-unconfirmed\",\"bundle\":\"%s\",\"pid\":%d,\"count\":%d}\n", bundle, pid, n); fclose(f); }
    }
}

// 三点命中探测：返回"现在屏幕上是哪个 App 的 pid"，0 表示主屏。rcOut 保留三次探测的 rc 供上层复核。
static int axHitProbePid(float x, float y, int *outPid);
static int axOnScreenPid(int rcOut[3]) {
    static const float pts[][2] = { { 215, 466 }, { 215, 720 }, { 215, 240 } };
    int np = (int)(sizeof(pts) / sizeof(pts[0]));
    int selfPid = (int)getpid();

    for (int i = 0; i < 3; i++) rcOut[i] = -999;

    for (int i = 0; i < np; i++) {
        int pid = 0;
        rcOut[i] = axHitProbePid(pts[i][0], pts[i][1], &pid);
        SBLogSync("WHR probe %.0f,%.0f rc=%d pid=%d", pts[i][0], pts[i][1], rcOut[i], pid);
        if (rcOut[i] == 0 && pid > 0 && pid != selfPid) return pid;
    }
    return 0;
}

// ------------------------------------------------------------------ whereami：只回答“现在有没有 App 在屏幕上”
// 一条真机事实：后台 App 的进程活着时，3015 依然有元素（设置退后台 n=13），
// 所以“有树”不能当作前台证据。可靠信号是 hit-test：App 在前时命中它的元素（rc=0 + pid），
// 主屏时所有点都 rc=-25204。故本命令用多点击中探测，全部落空才判 home。
static int axHitProbePid(float x, float y, int *outPid) {
    *outPid = 0;
    if (!g_axSysCreate || !g_axHitTest) return -1000;
    AXEl sw = NULL;
    @try { sw = g_axSysCreate(); } @catch (NSException *e) { (void)e; sw = NULL; }
    if (!sw) return -1001;
    if (g_axTimeout) g_axTimeout(sw, 0.4f);

    AXEl el = NULL;
    int rc = -999;
    @try { rc = g_axHitTest(sw, x, y, &el); } @catch (NSException *e) { (void)e; rc = -999; }
    if (rc == 0 && el) {
        int pid = 0;
        if (g_axGetPid) { @try { g_axGetPid(el, &pid); } @catch (NSException *e) { (void)e; pid = 0; } }
        *outPid = pid;
        CFRelease(el);
    } else if (el) {
        CFRelease(el);
    }
    CFRelease(sw);
    return rc;
}

static void axWhereAmI(void) {
    static const char *cands[] = { "设置", "天气", "电话", "信息", "相册", "时钟", "相机",
                                   "日历", "备忘录", "地图", "邮件", "音乐", "微信", "抖音", "Safari" };

    int rcOut[3];
    int pidHit = axOnScreenPid(rcOut);

    char appName[40] = { 0 };
    if (pidHit) {
        for (size_t i = 0; i < sizeof(cands) / sizeof(cands[0]); i++) {
            if (axPidByQuery(cands[i], NULL, 0) == pidHit) { snprintf(appName, sizeof(appName), "%s", cands[i]); break; }
        }
    }

    const char *state = pidHit ? "app" : "home";
    SBLogSync("WHR result state=%s pid=%d app=%s rc=%d,%d,%d", state, pidHit, appName, rcOut[0], rcOut[1], rcOut[2]);

    FILE *f = fopen(AX_WHERE_FILE, "w");
    if (f) {
        fprintf(f, "{\"ok\":1,\"mode\":\"whereami\",\"state\":\"%s\",\"pid\":%d,\"app\":\"%s\",\"rc\":[%d,%d,%d]}\n",
                state, pidHit, appName, rcOut[0], rcOut[1], rcOut[2]);
        fclose(f);
    }
}

// ------------------------------------------------------------------ flow：一条命令跑多步（open→where→act→shot）
// 语义：按行顺序执行，**任一步失败即停**，后续不再执行；结果汇总进 ax_flow.json。
static int axJsonStrOf(const char *path, const char *key, char *out, size_t cap) {
    out[0] = 0;
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    char buf[1024];
    size_t n = fread(buf, 1, sizeof(buf) - 1, f);
    buf[n] = 0;
    fclose(f);
    char pat[48];
    snprintf(pat, sizeof(pat), "\"%s\":\"", key);
    char *p = strstr(buf, pat);
    if (!p) return 0;
    p += strlen(pat);
    size_t i = 0;
    while (*p && *p != '"' && i + 1 < cap) out[i++] = *p++;
    out[i] = 0;
    return 1;
}

static int axJsonIntOf(const char *path, const char *key) {
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    char buf[1024];
    size_t n = fread(buf, 1, sizeof(buf) - 1, f);
    buf[n] = 0;
    fclose(f);
    char pat[48];
    snprintf(pat, sizeof(pat), "\"%s\":", key);
    char *p = strstr(buf, pat);
    if (!p) return -1;
    return atoi(p + strlen(pat));
}

static void axFlow(void) {
    FILE *cf = fopen(AX_FLOW_CMD, "r");
    if (!cf) { SBLogSync("FLOW no-cmd %s", AX_FLOW_CMD); return; }

    FILE *of = fopen(AX_FLOW_FILE, "w");
    if (of) fputs("{\"steps\":[", of);

    char line[256];
    int i = 0, failed = 0, first = 1;

    while (i < 10 && fgets(line, sizeof(line), cf)) {
        char *s = line;
        while (*s == ' ' || *s == '\t') s++;
        size_t L = strlen(s);
        while (L && (s[L - 1] == '\n' || s[L - 1] == '\r' || s[L - 1] == ' ' || s[L - 1] == '\t')) s[--L] = 0;
        if (!*s || *s == '#') continue;
        i++;

        char reason[64] = { 0 };
        int pid = -1, ok = 1;

        if (!strcmp(s, "where")) {
            axWhereAmI();
            axJsonStrOf(AX_WHERE_FILE, "state", reason, sizeof(reason));
            pid = axJsonIntOf(AX_WHERE_FILE, "pid");
        } else if (!strcmp(s, "shot")) {
            int rc = SBScreenShotNow(0, 0, 0);
            snprintf(reason, sizeof(reason), "shot-rc%d", rc);
            ok = (rc == 0);
        } else if (!strncmp(s, "sleep ", 6)) {
            int ms = atoi(s + 6);
            if (ms > 0 && ms <= 5000) usleep(ms * 1000);
            snprintf(reason, sizeof(reason), "slept");
        } else if (!strncmp(s, "open ", 5)) {
            axOpenApp(s + 5);
            axJsonStrOf(AX_LAUNCH_FILE, "reason", reason, sizeof(reason));
            pid = axJsonIntOf(AX_LAUNCH_FILE, "pid");
            ok = !strcmp(reason, "launched-confirmed");
            if (ok) {
                // 树起来了不等于到前台，再补一次屏幕上确认
                int rcs[3];
                int onp = axOnScreenPid(rcs);
                if (onp != pid) { ok = 0; snprintf(reason, sizeof(reason), "not-front"); }
            }
        } else if (!strncmp(s, "act ", 4)) {
            char tgt[64] = { 0 };
            int ti = 0;
            const char *r = s + 4;
            while (*r == ' ') r++;
            while (*r && *r != ' ' && ti < 63) tgt[ti++] = *r++;
            while (*r == ' ') r++;
            if (!tgt[0] || !*r) {
                ok = 0;
                snprintf(reason, sizeof(reason), "bad-act");
            } else {
                axAct(tgt, r);
                axJsonStrOf(AX_ACT_FILE, "reason", reason, sizeof(reason));
                pid = axJsonIntOf(AX_ACT_FILE, "pid");
                ok = !strcmp(reason, "confirmed");
            }
        } else {
            ok = 0;
            snprintf(reason, sizeof(reason), "bad-cmd");
        }

        SBLogSync("FLOW step %d cmd='%s' ok=%d reason=%s pid=%d", i, s, ok, reason, pid);
        if (of) {
            if (!first) fputs(",", of);
            first = 0;
            fprintf(of, "{\"i\":%d,\"cmd\":\"%s\",\"ok\":%d,\"reason\":\"%s\",\"pid\":%d}", i, s, ok, reason, pid);
        }
        if (!ok) { failed = 1; break; }
    }
    fclose(cf);

    if (of) {
        fprintf(of, "],\"ok\":%d,\"failed\":%d}\n", failed ? 0 : 1, failed);
        fclose(of);
    }
    SBLogSync("FLOW done ok=%d steps=%d", failed ? 0 : 1, i);
}

static void axListApps(void) {
    Class ctl = objc_getClass("SBApplicationController");
    if (!ctl) { SBLogSync("AX apps: no SBApplicationController"); return; }
    id inst = ((id (*)(id, SEL))objc_msgSend)((id)ctl, sel_registerName("sharedInstance"));
    if (!inst) { SBLogSync("AX apps: no sharedInstance"); return; }

    id list = NULL;
    @try {
        list = ((id (*)(id, SEL))objc_msgSend)(inst, sel_registerName("applications"));
        if (list && ((BOOL (*)(id, SEL, SEL))objc_msgSend)(list, sel_registerName("respondsToSelector:"), sel_registerName("allObjects"))) {
            list = ((id (*)(id, SEL))objc_msgSend)(list, sel_registerName("allObjects"));
        }
    } @catch (NSException *e) { (void)e; list = NULL; }

    if (!list) { SBLogSync("AX apps: list nil"); return; }

    unsigned long n = ((unsigned long (*)(id, SEL))objc_msgSend)(list, sel_registerName("count"));
    SBLogSync("AX apps n=%lu", n);

    for (unsigned long i = 0; i < n && i < 40; i++) {
        id app = ((id (*)(id, SEL, unsigned long))objc_msgSend)(list, sel_registerName("objectAtIndex:"), i);
        if (!app) continue;
        int pid = ((int (*)(id, SEL))objc_msgSend)(app, sel_registerName("pid"));
        id bid = ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("bundleIdentifier"));
        char b[128];
        axCFStrTo(b, sizeof(b), (CFStringRef)bid);
        SBLogSync("AX app i=%lu pid=%d bundle=%s", i, pid, b);
    }
}

static void axState(void) {
    AXFront fr = { 0, "" };
    axFrontApp(&fr);
    SBLogSync("AX state active=%d client=%d queries=%d hits=%d fails=%d front=%d/%s thread=%d",
              g_axActive, g_axClientSet, g_axQueries, g_axHits, g_axFails,
              fr.pid, fr.bundle, g_axThreadUp);
}

// objcs：只读枚举 objc 运行时（类名/选择子子串），用于在 dyld 缓存里找候选接口
static void axObjcScan(const char *clsSub, const char *selSub) {
    int n = objc_getClassList(NULL, 0);
    if (n <= 0) { SBLogSync("OC n=0"); return; }
    Class *list = (Class *)malloc(sizeof(Class) * (size_t)n);
    if (!list) { SBLogSync("OC malloc fail"); return; }
    n = objc_getClassList(list, n);

    FILE *f = fopen(AX_OBJC_FILE, "w");
    int outCls = 0;
    if (f) fprintf(f, "{\"mode\":\"objcs\",\"cls\":\"%s\",\"sel\":\"%s\",\"items\":[", clsSub, selSub);
    for (int i = 0; i < n && outCls < 24; i++) {
        const char *cn = class_getName(list[i]);
        if (!cn || cn[0] == '_') continue;
        if (!axCaseContains(cn, clsSub)) continue;
        unsigned mc = 0;
        Method *ms = class_copyMethodList(list[i], &mc);
        int wrote = 0;
        if (f) fprintf(f, "%s{\"cls\":\"%s\",\"sels\":[", outCls ? "," : "", cn);
        for (unsigned j = 0; j < mc && wrote < 16; j++) {
            const char *sn = sel_getName(method_getName(ms[j]));
            if (!sn) continue;
            if (selSub[0] && !axCaseContains(sn, selSub)) continue;
            if (f) fprintf(f, "%s\"%s\"", wrote ? "," : "", sn);
            wrote++;
        }
        if (ms) free(ms);
        // 类方法在元类里，单独扫一遍（+ 前缀）
        unsigned mcm = 0;
        Method *msm = class_copyMethodList(object_getClass((id)list[i]), &mcm);
        for (unsigned j = 0; j < mcm && wrote < 24; j++) {
            const char *sn = sel_getName(method_getName(msm[j]));
            if (!sn) continue;
            if (selSub[0] && !axCaseContains(sn, selSub)) continue;
            if (f) fprintf(f, "%s\"+%s\"", wrote ? "," : "", sn);
            wrote++;
        }
        if (msm) free(msm);
        if (f) fprintf(f, "]}");
        outCls++;
    }
    if (f) { fprintf(f, "],\"classes\":%d}", outCls); fclose(f); }
    free(list);
    SBLogSync("OC scan cls=%s sel=%s classes=%d", clsSub, selSub, outCls);
}

static int axHandleLine(char *line) {
    char *op = line;
    while (*op == ' ' || *op == '\t') op++;
    if (!*op) return 0;

    if (!strcmp(op, "state") || !strcmp(op, "info")) { axState(); return 1; }

    if (!strcmp(op, "apps")) { axListApps(); return 1; }

    if (!strcmp(op, "probe")) { axDlProbe(); return 1; }

    if (!strcmp(op, "sw")) { axSystemWide(); return 1; }
    if (!strcmp(op, "num")) { axNumericProbe(); return 1; }
    if (!strcmp(op, "sym")) { axSymProbe(); return 1; }
    if (!strcmp(op, "dump")) { axDumpTree(); return 1; }

    if (!strcmp(op, "frontname")) {
        SBLogSync("AXN3 front-nic=%s", g_frontBundle[0] ? g_frontBundle : "(none)");
        return 1;
    }

    if (!strncmp(op, "matrix", 6)) {
        SBLogSync("AXM disabled (hangs SpringBoard watchdog on iOS 17)");
        return 1;
    }

    if (!strcmp(op, "symx")) { axSymScan(); return 1; }

    if (!strncmp(op, "objcs", 5)) {
        char clsSub[64] = { 0 }, selSub[64] = { 0 };
        const char *r2 = op + 5;
        while (*r2 == ' ') r2++;
        int ti2 = 0;
        while (*r2 && *r2 != ' ' && ti2 < 63) clsSub[ti2++] = *r2++;
        while (*r2 == ' ') r2++;
        ti2 = 0;
        while (*r2 && *r2 != ' ' && ti2 < 63) selSub[ti2++] = *r2++;
        if (!clsSub[0]) { SBLogSync("OC usage: objcs <类名子串> [选择子子串]"); return 1; }
        axObjcScan(clsSub, selSub);
        return 1;
    }

    if (!strncmp(op, "openapp ", 8)) {
        const char *t = op + 8;
        while (*t == ' ') t++;
        if (*t) axOpenApp(t);
        else SBLogSync("OPEN usage: openapp <名字或bundle>");
        return 1;
    }

    if (!strncmp(op, "findq ", 6) || !strncmp(op, "tapq ", 5)) {
        int isTap = !strncmp(op, "tapq ", 5);
        char target[128] = { 0 };
        const char *rest = op + (isTap ? 5 : 6);
        while (*rest == ' ') rest++;
        int ti = 0;
        while (*rest && *rest != ' ' && ti < 127) target[ti++] = *rest++;
        while (*rest == ' ') rest++;
        if (target[0] && rest[0]) axQuery(target, rest, isTap);
        else SBLogSync("FQ usage: %s <app名或pid> label=子串[&traits=..][&region=x1,y1,x2,y2][&idx=N]", isTap ? "tapq" : "findq");
        return 1;
    }

    if (!strncmp(op, "actf ", 5)) {
        char target[128] = { 0 };
        const char *rest = op + 5;
        while (*rest == ' ') rest++;
        int ti = 0;
        while (*rest && *rest != ' ' && ti < 127) target[ti++] = *rest++;
        while (*rest == ' ') rest++;
        if (target[0] && rest[0]) {
            g_axSkipFrontCheck = 1;
            SBLogSync("ACT force: 跳过屏幕预检 target=%s", target);
            axAct(target, rest);
            g_axSkipFrontCheck = 0;
        } else {
            SBLogSync("ACT usage: actf <app名或pid> <文案>");
        }
        return 1;
    }

    if (!strncmp(op, "act ", 4)) {
        char target[128] = { 0 };
        const char *rest = op + 4;
        while (*rest == ' ') rest++;
        int ti = 0;
        while (*rest && *rest != ' ' && ti < 127) target[ti++] = *rest++;
        while (*rest == ' ') rest++;
        if (target[0] && rest[0]) axAct(target, rest);
        else SBLogSync("ACT usage: act <app名或pid> <文案>");
        return 1;
    }

    if (!strncmp(op, "hitpid", 6)) {
        float hx = 215.0f, hy = 466.0f;
        sscanf(op + 6, "%f %f", &hx, &hy);
        axHitPid(hx, hy);
        return 1;
    }

    if (!strcmp(op, "whereami") || !strcmp(op, "where")) { axWhereAmI(); return 1; }

    if (!strcmp(op, "flow")) { axFlow(); return 1; }

    if (!strncmp(op, "pidof", 5)) {
        const char *q = op + 5;
        while (*q == ' ') q++;
        axPidOf(q);
        return 1;
    }

    if (!strcmp(op, "count")) {
        SBLogSync("AXC2 disabled (blind pid scan blocks SpringBoard watchdog); use frontpid");
        return 1;
    }

    if (!strcmp(op, "frontpid")) {
        // 禁用：AXFrontBoardFocusedAppPID 调用链内部有未解析 stub（brk #0x1 → SIGTRAP → 安全模式）
        SBLogSync("AXF frontpid disabled (trap on iOS 17); use hitpid/frontguess");
        return 1;
    }

    if (!strcmp(op, "frontguess")) {
        // 屏幕中心命中：用“这个点上的元素属于谁”来替代所有前台判定
        axHitPid(215.0f, 466.0f);
        return 1;
    }

    if (!strcmp(op, "frontscan")) { SBLogSync("AXF2 frontscan disabled"); return 1; }

    if (!strcmp(op, "appstates")) { SBLogSync("AXF2 appstates disabled"); return 1; }

    if (!strcmp(op, "frontauto")) { SBLogSync("AXF2 frontauto disabled"); return 1; }

    if (!strcmp(op, "frontprobe")) { SBLogSync("AXF2 frontprobe disabled"); return 1; }

    if (!strncmp(op, "scrolldump", 10)) {
        int n = 3;
        sscanf(op + 10, "%d", &n);
        axScrollDump(n);
        return 1;
    }

    if (!strncmp(op, "find", 4)) {
        const char *p = op + 4; while (*p == ' ') p++;
        axFindLabel(p, 0);
        return 1;
    }

    if (!strncmp(op, "tapfind", 7)) {
        const char *p = op + 7; while (*p == ' ') p++;
        axFindLabel(p, 1);
        return 1;
    }

    if (!strncmp(op, "keys", 4)) {
        int idx = 1;
        sscanf(op + 4, "%d", &idx);
        axKeysProbe(idx);
        return 1;
    }

    if (!strncmp(op, "scan", 4)) {
        double a = 0, b = 0, c = 0;
        int cnt = sscanf(op + 4, "%lf %lf %lf", &a, &b, &c);
        int idx = (cnt >= 1) ? (int)a : 1;
        int lo = (cnt >= 3) ? (int)b : 2000;
        int hi = (cnt >= 3) ? (int)c : 2250;
        axScanIds(idx, lo, hi);
        return 1;
    }
    if (!strcmp(op, "attrs")) { axAttrsAt(0, 0, 0); return 1; }

    if (!strncmp(op, "attrsat", 7)) {
        double x = 0, y = 0;
        if (sscanf(op + 7, "%lf %lf", &x, &y) == 2) axAttrsAt(1, x, y);
        return 1;
    }

    if (!strcmp(op, "names")) { axNamesAt(0, 0, 0); return 1; }

    if (!strncmp(op, "namesat", 7)) {
        double x = 0, y = 0;
        if (sscanf(op + 7, "%lf %lf", &x, &y) == 2) axNamesAt(1, x, y);
        return 1;
    }

    if (!strncmp(op, "ap", 2)) {
        double p = 0;
        if (sscanf(op + 2, "%lf", &p) == 1 && p >= 0) {
            g_axTargetPid = (int)p;
            SBLogSync("AX target pid set %d", g_axTargetPid);
        }
        return 1;
    }

    if (!strcmp(op, "front")) {
        SBLogSync("AX front disabled (all front query paths dead on iOS 17); use hitpid/frontguess");
        return 1;
    }

    if (!strncmp(op, "tapat", 5)) {
        double x = 0, y = 0;
        if (sscanf(op + 5, "%lf %lf", &x, &y) == 2) {
            AXElInfo a, b;
            axDoQuery(x, y, "tap", 1, &a, &b);
        }
        return 1;
    }

    if (!strncmp(op, "at", 2)) {
        double x = 0, y = 0;
        if (sscanf(op + 2, "%lf %lf", &x, &y) == 2) {
            AXElInfo a;
            axDoQuery(x, y, "at", 0, &a, NULL);
        }
        return 1;
    }

    return 0;
}

static void axPollOnce(void) {
    FILE *f = fopen(AX_CMD_FILE, "r");
    if (!f) return;

    char buf[256];
    int handled = 0;
    while (fgets(buf, sizeof(buf), f)) {
        char *p = strchr(buf, '\n');
        if (p) *p = 0;
        p = strchr(buf, '\r');
        if (p) *p = 0;
        char *s = buf;
        while (*s == ' ' || *s == '\t') s++;
        if (!*s) continue;
        axHandleLine(s);
        handled = 1;
        break;
    }
    fclose(f);
    if (handled) unlink(AX_CMD_FILE);
}

static void *axThreadMain(void *arg) {
    (void)arg;
    axMarker("thread-enter");
    axResolve();

    int tick = 0;
    while (1) {
        tick++;
        pthread_testcancel();
        if ((tick % 10) == 0) axPollOnce();
        usleep(30000);
    }
    return NULL;
}

void SBAxisBoot(void) {    axMarker("boot-enter");
    SBLogSync("AX boot enter");
    if (g_axThreadUp) { SBLogSync("AX boot skip (already)"); return; }
    axSetupFrontNotifications();    if (pthread_create(&g_axThread, NULL, axThreadMain, NULL) != 0) {
        axMarker("thread-fail");
        SBLogSync("AX boot thread fail");
        return;
    }
    g_axThreadUp = 1;
    axMarker("thread-spawned");
}

const char *SBAxisStatus(void) {
    static char s[220];
    snprintf(s, sizeof(s), "active=%d client=%d q=%d hit=%d fail=%d",
             g_axActive, g_axClientSet, g_axQueries, g_axHits, g_axFails);
    return s;
}


