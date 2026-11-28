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

#define AX_CMD_FILE  SB_HOME_DIR "/ax.cmd"
#define AX_OUT_FILE  SB_HOME_DIR "/ax_out.json"
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
static int                     g_axTargetPid = 0;   // ap 命令手工指定目标进程

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

    g_axValueGet = (AXValueGetValueFn)dlsym(RTLD_DEFAULT, "AXValueGetValue");
    if (!g_axValueGet && h) g_axValueGet = (AXValueGetValueFn)dlsym(h, "AXValueGetValue");

    g_axSysCreate = (AXSysCreateFn)dlsym(RTLD_DEFAULT, "AXUIElementCreateSystemWide");
    if (!g_axSysCreate && h) g_axSysCreate = (AXSysCreateFn)dlsym(h, "AXUIElementCreateSystemWide");
    g_axGetPid = (AXGetPidFn)dlsym(RTLD_DEFAULT, "AXUIElementGetPid");
    if (!g_axGetPid && h) g_axGetPid = (AXGetPidFn)dlsym(h, "AXUIElementGetPid");

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

static void axListApps(void) {
    Class ctl = objc_getClass("SBApplicationController");
    if (!ctl) { SBLogSync("AX apps: no SBApplicationController"); return; }
    id inst = ((id (*)(id, SEL))objc_msgSend)((id)ctl, sel_registerName("sharedInstance"));
    if (!inst) { SBLogSync("AX apps: no sharedInstance"); return; }

    id list = NULL;
    @try {
        list = ((id (*)(id, SEL))objc_msgSend)(inst, sel_registerName("applications"));
        if (list && ((BOOL (*)(id, SEL))objc_msgSend)(list, sel_registerName("respondsToSelector:"), sel_registerName("allObjects"))) {
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

static int axHandleLine(char *line) {
    char *op = line;
    while (*op == ' ' || *op == '\t') op++;
    if (!*op) return 0;

    if (!strcmp(op, "state") || !strcmp(op, "info")) { axState(); return 1; }

    if (!strcmp(op, "apps")) { axListApps(); return 1; }

    if (!strncmp(op, "ap", 2)) {
        double p = 0;
        if (sscanf(op + 2, "%lf", &p) == 1 && p >= 0) {
            g_axTargetPid = (int)p;
            SBLogSync("AX target pid set %d", g_axTargetPid);
        }
        return 1;
    }

    if (!strcmp(op, "front")) {
        AXFront fr = { 0, "" };
        int r = axFrontApp(&fr);
        SBLogSync("AX front r=%d pid=%d bundle=%s", r, fr.pid, fr.bundle);
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

void SBAxisBoot(void) {
    axMarker("boot-enter");
    SBLogSync("AX boot enter");
    if (g_axThreadUp) { SBLogSync("AX boot skip (already)"); return; }
    if (pthread_create(&g_axThread, NULL, axThreadMain, NULL) != 0) {
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
