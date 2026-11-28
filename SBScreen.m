// SBScreen.m — 1.7.4
// 观察层第一块：截图。跑在 SpringBoard 进程内，纯 C/CF + ImageIO，不碰 UIKit 的 UI 栈、不碰 UIScreen。
//
// 为什么不用 UIKit 那套：本机 RootHide 下 dispatch 到主队列的任务不执行，而 UIScreen.mainScreen /
// _UICreateScreenUIImage 必须在主线程（1.7.0 就是这么 abort 进安全模式的）。
//
// 1.7.3 实测：CARenderServerCaptureDisplay(0,"LCD"/"Main"/"Display") 三条全部返回 null。
// 1.7.4 改用 ZXTouch 验证过的路线（其 Screen.xm: createScreenShotCGImageRef）：
//   自建 IOSurface(BGRA) → IOSurfaceLock → CARenderServerRenderDisplay(0,"LCD",surface,0,0)
//   → UICreateCGImageFromIOSurface(surface) → IOSurfaceUnlock → 降采样 → JPEG。
// 这条链在线程池里跑是安全的（ZXTouch 的 socket 线程也这么干）。
//
// 命令通道：SB_HOME_DIR/screen.cmd（root 侧写 /rootfs/private/var/... 同一文件）
//   shot            按点尺寸(默认 430x932)降采样输出
//   shot W H        指定点尺寸
//   shot raw        原像素不降采样
//   shotb64         额外落一份 base64 文本，方便 ssh 侧直接看
//   size W H        只改点尺寸
//   scale N         改渲染倍率（默认 3）
//   state / info    只回状态
// 输出：SB_HOME_DIR/shot.jpg（二进制 JPEG），日志一行 SCR shot ...

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
#import <ImageIO/ImageIO.h>

#define SC_CMD_FILE   SB_HOME_DIR "/screen.cmd"
#define SC_JPG_FILE   SB_HOME_DIR "/shot.jpg"
#define SC_B64_FILE   SB_HOME_DIR "/shot.b64"
#define SC_MARK_FILE  SB_HOME_DIR "/screen_boot.txt"

typedef struct __IOSurface *SCSurfaceRef;
typedef SCSurfaceRef (*SCSurfaceCreateFn)(CFDictionaryRef properties);
typedef int (*SCSurfaceLockFn)(SCSurfaceRef s, unsigned int options, unsigned int *seed);
typedef int (*SCSurfaceUnlockFn)(SCSurfaceRef s, unsigned int options, unsigned int *seed);
typedef void (*SCRenderDisplayFn)(int displayId, CFStringRef name, SCSurfaceRef surface, int x, int y);
typedef CGImageRef (*SCRenderCapFn)(uint32_t serverPort, CFStringRef displayName, CFDictionaryRef options);
typedef CGImageRef (*SCUICreateFromSurfaceFn)(SCSurfaceRef surface);

static SCSurfaceCreateFn      g_scSurfaceCreate = NULL;
static SCSurfaceLockFn        g_scSurfaceLock = NULL;
static SCSurfaceUnlockFn      g_scSurfaceUnlock = NULL;
static SCRenderDisplayFn      g_scRenderDisplay = NULL;
static SCUICreateFromSurfaceFn g_scFromSurface = NULL;
static SCRenderCapFn          g_scCap = NULL;
static int      g_scCapTried = 0;
static int      g_scPtW = 430;      // 点宽（与 SBTouch 缺省一致）
static int      g_scPtH = 932;      // 点高
static int      g_scScale = 3;      // 渲染倍率
static int      g_scWantUikit = 0;  // 一次性开关：下一次 shot 走 _UICreateScreenUIImage
static int      g_scShots = 0;
static int      g_scFails = 0;
static pthread_t g_scThread;
static int      g_scThreadUp = 0;

// ------------------------------------------------------------------ 工具

static CFStringRef scCFStr(const char *s) {
    if (!s) return NULL;
    return CFStringCreateWithCString(NULL, s, kCFStringEncodingUTF8);
}

static void scMarker(const char *tag) {
    FILE *f = fopen(SC_MARK_FILE, "a");
    if (!f) return;
    struct timeval tv;
    gettimeofday(&tv, NULL);
    fprintf(f, "%ld %s\n", (long)tv.tv_sec, tag);
    fflush(f);
    fclose(f);
}

static long scNowMs(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec * 1000L + tv.tv_usec / 1000L;
}

// ------------------------------------------------------------------ 符号

static int scResolve(void) {
    if (g_scCapTried) return 1;
    g_scCapTried = 1;

    void *qz = dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_LAZY);
    if (qz) {
        g_scRenderDisplay = (SCRenderDisplayFn)dlsym(qz, "CARenderServerRenderDisplay");
        g_scCap = (SCRenderCapFn)dlsym(qz, "CARenderServerCaptureDisplay");
    }
    if (!g_scRenderDisplay) g_scRenderDisplay = (SCRenderDisplayFn)dlsym(RTLD_DEFAULT, "CARenderServerRenderDisplay");
    if (!g_scCap) g_scCap = (SCRenderCapFn)dlsym(RTLD_DEFAULT, "CARenderServerCaptureDisplay");

    void *isf = dlopen("/System/Library/PrivateFrameworks/IOSurface.framework/IOSurface", RTLD_LAZY);
    if (!isf) isf = dlopen("/System/Library/Frameworks/IOSurface.framework/IOSurface", RTLD_LAZY);
    if (isf) {
        g_scSurfaceCreate = (SCSurfaceCreateFn)dlsym(isf, "IOSurfaceCreate");
        g_scSurfaceLock = (SCSurfaceLockFn)dlsym(isf, "IOSurfaceLock");
        g_scSurfaceUnlock = (SCSurfaceUnlockFn)dlsym(isf, "IOSurfaceUnLock");
        if (!g_scSurfaceUnlock) g_scSurfaceUnlock = (SCSurfaceUnlockFn)dlsym(isf, "IOSurfaceUnlock");
    }
    if (!g_scSurfaceCreate) g_scSurfaceCreate = (SCSurfaceCreateFn)dlsym(RTLD_DEFAULT, "IOSurfaceCreate");
    if (!g_scSurfaceLock) g_scSurfaceLock = (SCSurfaceLockFn)dlsym(RTLD_DEFAULT, "IOSurfaceLock");
    if (!g_scSurfaceUnlock) g_scSurfaceUnlock = (SCSurfaceUnlockFn)dlsym(RTLD_DEFAULT, "IOSurfaceUnLock");

    g_scFromSurface = (SCUICreateFromSurfaceFn)dlsym(RTLD_DEFAULT, "UICreateCGImageFromIOSurface");

    SBLogSync("SCR sym render=%d cap=%d surf=%d lock=%d fromsurf=%d",
              g_scRenderDisplay ? 1 : 0, g_scCap ? 1 : 0,
              (g_scSurfaceCreate && g_scSurfaceLock && g_scSurfaceUnlock) ? 1 : 0,
              g_scSurfaceLock ? 1 : 0, g_scFromSurface ? 1 : 0);
    return 1;
}

// ------------------------------------------------------------------ 捕获：IOSurface + RenderDisplay

static CFNumberRef scNum(int v) {
    return CFNumberCreate(NULL, kCFNumberIntType, &v);
}

static void scDictSet(CFMutableDictionaryRef d, const char *key, int value) {
    CFStringRef k = scCFStr(key);
    CFNumberRef n = scNum(value);
    if (k && n) CFDictionarySetValue(d, k, n);
    if (k) CFRelease(k);
    if (n) CFRelease(n);
}

static CGImageRef scCaptureViaRender(const char **why) {
    if (!g_scRenderDisplay || !g_scSurfaceCreate || !g_scSurfaceLock ||
        !g_scSurfaceUnlock || !g_scFromSurface) {
        if (why) *why = "sym-missing";
        return NULL;
    }

    int pw = g_scPtW * g_scScale;
    int ph = g_scPtH * g_scScale;
    if (pw < 1 || ph < 1) { if (why) *why = "bad-size"; return NULL; }

    int bytesPerRow = ((4 * pw) + 31) & ~31;   // 32 字节对齐
    CFMutableDictionaryRef props = CFDictionaryCreateMutable(NULL, 0,
                                                             &kCFTypeDictionaryKeyCallBacks,
                                                             &kCFTypeDictionaryValueCallBacks);
    if (!props) { if (why) *why = "no-dict"; return NULL; }
    scDictSet(props, "IOSurfaceWidth", pw);
    scDictSet(props, "IOSurfaceHeight", ph);
    scDictSet(props, "IOSurfaceBytesPerElement", 4);
    scDictSet(props, "IOSurfaceBytesPerRow", bytesPerRow);
    scDictSet(props, "IOSurfaceAllocSize", bytesPerRow * ph);
    scDictSet(props, "IOSurfacePixelFormat", 1111970369);   // 'BGRA'
    scDictSet(props, "IOSurfaceIsGlobal", 1);

    SCSurfaceRef surf = g_scSurfaceCreate(props);
    CFRelease(props);
    if (!surf) { if (why) *why = "surface-null"; return NULL; }

    if (g_scSurfaceLock(surf, 0, NULL) != 0) {
        CFRelease(surf);
        if (why) *why = "lock-fail";
        return NULL;
    }

    CFStringRef disp = scCFStr("LCD");
    g_scRenderDisplay(0, disp, surf, 0, 0);
    if (disp) CFRelease(disp);

    CGImageRef img = g_scFromSurface(surf);
    g_scSurfaceUnlock(surf, 0, NULL);
    CFRelease(surf);

    if (!img) { if (why) *why = "cgimage-null"; return NULL; }
    if (why) *why = "iosurface-render";
    return img;   // +1（框架返回的引用）
}

// 旧路线：渲染服务器直接吞吐（本机实测恒 null，留作对照）
static CGImageRef scCaptureViaServer(const char **why) {
    if (!g_scCap) { if (why) *why = "no-sym"; return NULL; }
    const char *names[3] = { "LCD", "Main", "Display" };
    for (int i = 0; i < 3; i++) {
        CFStringRef nm = scCFStr(names[i]);
        if (!nm) continue;
        CGImageRef img = g_scCap(0, nm, NULL);
        CFRelease(nm);
        if (img) { if (why) *why = names[i]; return img; }
    }
    if (why) *why = "all-null";
    return NULL;
}

// 路线二：UIKit 的屏面 surface（ios-mcp 首选路径）。类方法，不需要 UIScreen。
static CGImageRef scCaptureViaWindowSurface(const char **why) {
    Class wcls = objc_getClass("UIWindow");
    if (!wcls || !g_scFromSurface) { if (why) *why = "no-sym2"; return NULL; }

    SCSurfaceRef surf = NULL;
    @try {
        surf = (SCSurfaceRef)((id (*)(id, SEL))objc_msgSend)((id)wcls, sel_registerName("createScreenIOSurface"));
    } @catch (NSException *e) {
        (void)e;
        surf = NULL;
    }
    if (!surf) { if (why) *why = "surface-null2"; return NULL; }

    CGImageRef img = g_scFromSurface(surf);
    CFRelease(surf);
    if (!img) { if (why) *why = "cgimage-null2"; return NULL; }
    if (why) *why = "window-surface";
    return img;
}

// 路线三（默认关闭，靠 shot uikit 触发）：_UICreateScreenUIImage。回主线程执行，避免 UIKit 断言。
typedef id (*SCCreateScreenUIImageFn)(void);
static SCCreateScreenUIImageFn g_scScreenUIImage = NULL;

typedef struct {
    volatile int done;
    CGImageRef img;
} SCUikitJob;

static void scUikitPerform(const void *ctx) {
    SCUikitJob *job = (SCUikitJob *)(uintptr_t)ctx;
    if (!g_scScreenUIImage) g_scScreenUIImage = (SCCreateScreenUIImageFn)dlsym(RTLD_DEFAULT, "_UICreateScreenUIImage");
    if (g_scScreenUIImage) {
        id ui = NULL;
        @try { ui = g_scScreenUIImage(); } @catch (NSException *e) { (void)e; ui = NULL; }
        if (ui) {
            CGImageRef cg = NULL;
            @try { cg = (CGImageRef)((id (*)(id, SEL))objc_msgSend)(ui, sel_registerName("CGImage")); } @catch (NSException *e) { (void)e; }
            if (cg) {
                CGImageRetain(cg);
                job->img = cg;
            }
        }
    }
    job->done = 1;
    CFRunLoopWakeUp(CFRunLoopGetMain());
}

static CGImageRef scCaptureViaUIKit(const char **why) {
    SCUikitJob job = { 0, NULL };
    CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{
        scUikitPerform(&job);
    });
    CFRunLoopWakeUp(CFRunLoopGetMain());

    long waitMs = 0;
    while (!job.done && waitMs < 2500) {
        usleep(20000);
        waitMs += 20;
    }
    if (!job.done) { if (why) *why = "uikit-timeout"; return NULL; }
    if (!job.img) { if (why) *why = "uikit-null"; return NULL; }
    if (why) *why = "_UICreateScreenUIImage";
    return job.img;
}

// 返回 +1 引用，调用方负责 CGImageRelease
static CGImageRef scCapture(const char **srcOut) {
    scResolve();
    const char *why = "(none)";

    if (g_scWantUikit) {
        CGImageRef u = scCaptureViaUIKit(&why);
        if (u) { if (srcOut) *srcOut = why; return u; }
        SBLogSync("SCR uikit fail %s", why);
    }

    CGImageRef img = scCaptureViaWindowSurface(&why);
    if (img) { if (srcOut) *srcOut = why; return img; }
    SBLogSync("SCR windowsurf fail %s", why);

    img = scCaptureViaRender(&why);
    if (img) { if (srcOut) *srcOut = why; return img; }
    SBLogSync("SCR render fail %s", why);

    img = scCaptureViaServer(&why);
    if (img) { if (srcOut) *srcOut = why; return img; }
    SBLogSync("SCR server fail %s", why);

    if (srcOut) *srcOut = "(fail)";
    return NULL;
}

// ------------------------------------------------------------------ 降采样 / 编码 / 落盘

// 降采样到点尺寸：按长边比值缩放，保持宽高比（与 ios-mcp 的 MCPPointSizeForPixelSize 同思路）
static CGImageRef scDownsample(CGImageRef src, int tw, int th) {
    if (!src) return NULL;
    size_t pw = CGImageGetWidth(src), ph = CGImageGetHeight(src);
    if (pw < 1 || ph < 1) return NULL;

    double pLong = (pw > ph) ? (double)pw : (double)ph;
    double tLong = (tw > th) ? (double)tw : (double)th;
    if (tLong < 1.0) return NULL;

    double ratio = pLong / tLong;
    if (ratio <= 1.01) return NULL;   // 已经不比点尺寸大，不动

    size_t nw = (size_t)(pw / ratio + 0.5);
    size_t nh = (size_t)(ph / ratio + 0.5);
    if (nw < 1 || nh < 1) return NULL;

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    if (!cs) return NULL;
    CGContextRef ctx = CGBitmapContextCreate(NULL, nw, nh, 8, 0, cs,
                                             kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    if (!ctx) return NULL;

    CGContextSetInterpolationQuality(ctx, kCGInterpolationMedium);
    CGContextDrawImage(ctx, CGRectMake(0, 0, (CGFloat)nw, (CGFloat)nh), src);
    CGImageRef out = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return out;   // +1
}

static CFDataRef scEncodeJPEG(CGImageRef img, double quality) {
    if (!img) return NULL;
    CFMutableDataRef data = CFDataCreateMutable(NULL, 0);
    if (!data) return NULL;

    CFStringRef uti = scCFStr("public.jpeg");
    CGImageDestinationRef dest = CGImageDestinationCreateWithData(data, uti, 1, NULL);
    if (uti) CFRelease(uti);
    if (!dest) { CFRelease(data); return NULL; }

    const void *keys[1] = { kCGImageDestinationLossyCompressionQuality };
    CFNumberRef q = CFNumberCreate(NULL, kCFNumberDoubleType, &quality);
    const void *vals[1] = { q };
    CFDictionaryRef opts = CFDictionaryCreate(NULL, keys, vals, 1,
                                             &kCFTypeDictionaryKeyCallBacks,
                                             &kCFTypeDictionaryValueCallBacks);
    CGImageDestinationAddImage(dest, img, opts);
    if (opts) CFRelease(opts);
    if (q) CFRelease(q);

    int ok = CGImageDestinationFinalize(dest) ? 1 : 0;
    CFRelease(dest);
    if (!ok) { CFRelease(data); return NULL; }
    return data;   // +1
}

static long scWriteFile(const char *path, CFDataRef data) {
    if (!path || !data) return -1;
    long len = (long)CFDataGetLength(data);
    FILE *f = fopen(path, "wb");
    if (!f) return -1;
    const UInt8 *p = CFDataGetBytePtr(data);
    long wrote = 0;
    if (p && len > 0) wrote = (long)fwrite(p, 1, (size_t)len, f);
    fflush(f);
    fclose(f);
    return wrote;
}

static long scWriteBase64(const char *path, CFDataRef data) {
    if (!path || !data) return -1;
    id nsdata = (__bridge id)data;
    SEL sel = sel_registerName("base64EncodedStringWithOptions:");
    id b64 = ((id (*)(id, SEL, unsigned long))objc_msgSend)(nsdata, sel, 0UL);
    if (!b64) return -1;

    const char *utf8 = (const char *)((const char *(*)(id, SEL))objc_msgSend)(b64, sel_registerName("UTF8String"));
    if (!utf8) return -1;

    FILE *f = fopen(path, "wb");
    if (!f) return -1;
    long len = (long)strlen(utf8);
    long wrote = (long)fwrite(utf8, 1, (size_t)len, f);
    fflush(f);
    fclose(f);
    return wrote;
}

// ------------------------------------------------------------------ 主流程

// 8x8 取样求平均色：黑屏 / 白屏一眼看出（黑图 JPEG 只有几 KB）
static void scAvgColor(CGImageRef img, int *r, int *g, int *b) {
    *r = *g = *b = -1;
    if (!img) return;
    unsigned char px[8 * 8 * 4];
    memset(px, 0, sizeof(px));
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    if (!cs) return;
    CGContextRef ctx = CGBitmapContextCreate(px, 8, 8, 8, 8 * 4, cs,
                                             kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    if (!ctx) return;
    CGContextDrawImage(ctx, CGRectMake(0, 0, 8, 8), img);
    CGContextRelease(ctx);

    int sr = 0, sg = 0, sb = 0;
    for (int i = 0; i < 64; i++) {
        sb += px[i * 4 + 0];
        sg += px[i * 4 + 1];
        sr += px[i * 4 + 2];
    }
    *r = sr / 64; *g = sg / 64; *b = sb / 64;
}

static int scDoShot(int tw, int th, int rawMode, int wantB64) {
    long t0 = scNowMs();
    const char *src = "(none)";
    CGImageRef srcImg = scCapture(&src);
    if (!srcImg) {
        g_scFails++;
        SBLogSync("SCR shot FAIL src=%s", src);
        return -1;
    }

    size_t pw = CGImageGetWidth(srcImg), ph = CGImageGetHeight(srcImg);
    if (tw < 1 || th < 1) { tw = g_scPtW; th = g_scPtH; }

    CGImageRef outImg = NULL;
    if (!rawMode) outImg = scDownsample(srcImg, tw, th);
    CGImageRef useImg = outImg ? outImg : srcImg;

    CFDataRef jpg = scEncodeJPEG(useImg, outImg ? 0.82 : 0.72);
    long wrote = scWriteFile(SC_JPG_FILE, jpg);
    long b64Len = -1;
    if (wantB64) b64Len = scWriteBase64(SC_B64_FILE, jpg);

    size_t ow = CGImageGetWidth(useImg), oh = CGImageGetHeight(useImg);
    int ar, ag, ab;
    scAvgColor(srcImg, &ar, &ag, &ab);
    SBLogSync("SCR shot src=%s px=%zux%zu -> pt=%zux%zu bytes=%ld file=%ld b64=%ld avg=%d,%d,%d ms=%ld n=%d fail=%d",
              src, pw, ph, ow, oh,
              jpg ? (long)CFDataGetLength(jpg) : -1L,
              wrote, b64Len, ar, ag, ab, scNowMs() - t0, g_scShots + 1, g_scFails);

    if (jpg) CFRelease(jpg);
    if (outImg) CGImageRelease(outImg);
    CGImageRelease(srcImg);
    g_scShots++;
    return (wrote > 0) ? 0 : -1;
}

static void scState(void) {
    SBLogSync("SCR state render=%d cap=%d pt=%dx%d scale=%d shots=%d fail=%d thread=%d",
              g_scRenderDisplay ? 1 : 0, g_scCap ? 1 : 0,
              g_scPtW, g_scPtH, g_scScale, g_scShots, g_scFails, g_scThreadUp);
}

static int scHandleLine(char *line) {
    char *op = line;
    while (*op == ' ' || *op == '\t') op++;
    if (!*op) return 0;

    if (!strcmp(op, "state") || !strcmp(op, "info")) { scState(); return 1; }

    if (!strncmp(op, "scale", 5)) {
        double n = 0;
        if (sscanf(op + 5, "%lf", &n) == 1 && n >= 1 && n <= 6) {
            g_scScale = (int)n;
            SBLogSync("SCR scale set %d", g_scScale);
        }
        return 1;
    }

    if (!strncmp(op, "shot", 4)) {
        int wantB64 = 0, raw = 0;
        int tw = 0, th = 0;
        char *rest = op + 4;
        while (*rest == ' ' || *rest == '\t') rest++;

        if (op[4] == 'b') { wantB64 = 1; }
        else if (!strcmp(rest, "raw")) { raw = 1; }
        else if (!strcmp(rest, "uikit")) { g_scWantUikit = 1; }
        else if (!strcmp(rest, "b64") || !strcmp(rest, "base64")) { wantB64 = 1; }
        else if (rest[0]) {
            double a = 0, b = 0;
            if (sscanf(rest, "%lf %lf", &a, &b) == 2 && a > 0 && b > 0) {
                tw = (int)a; th = (int)b;
                g_scPtW = tw; g_scPtH = th;
            }
        }

        scDoShot(tw, th, raw, wantB64);
        g_scWantUikit = 0;
        return 1;
    }
    if (!strncmp(op, "size", 4)) {
        double a = 0, b = 0;
        if (sscanf(op + 4, "%lf %lf", &a, &b) == 2 && a > 0 && b > 0) {
            g_scPtW = (int)a; g_scPtH = (int)b;
            SBLogSync("SCR size set %dx%d", g_scPtW, g_scPtH);
            return 1;
        }
    }
    return 0;
}

static void scPollOnce(void) {
    FILE *f = fopen(SC_CMD_FILE, "r");
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
        scHandleLine(s);
        handled = 1;
        break;
    }
    fclose(f);

    if (handled) unlink(SC_CMD_FILE);
}

static void *scThreadMain(void *arg) {
    (void)arg;
    scMarker("thread-enter");
    scResolve();

    int tick = 0;
    while (1) {
        tick++;
        pthread_testcancel();
        if ((tick % 10) == 0) scPollOnce();
        usleep(30000);
    }
    return NULL;
}

void SBScreenBoot(void) {
    scMarker("boot-enter");
    SBLogSync("SCR boot enter");
    if (g_scThreadUp) { SBLogSync("SCR boot skip (already)"); return; }

    if (pthread_create(&g_scThread, NULL, scThreadMain, NULL) != 0) {
        scMarker("thread-fail");
        SBLogSync("SCR boot thread fail");
        return;
    }
    g_scThreadUp = 1;
    scMarker("thread-spawned");
}

const char *SBScreenStatus(void) {
    static char s[200];
    snprintf(s, sizeof(s), "render=%d cap=%d pt=%dx%d scale=%d shots=%d fail=%d",
             g_scRenderDisplay ? 1 : 0, g_scCap ? 1 : 0,
             g_scPtW, g_scPtH, g_scScale, g_scShots, g_scFails);
    return s;
}

// 供其它模块（AI 侧）直接调用，不等命令文件
int SBScreenShotNow(int tw, int th, int wantB64) {
    return scDoShot(tw, th, 0, wantB64);
}
