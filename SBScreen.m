// SBScreen.m — 1.7.3
// 观察层第一块：截图。跑在 SpringBoard 进程内，纯 C/CF + ImageIO，不碰 UIKit、不碰 UIScreen。
//
// 为什么不用 UIKit：本机 RootHide 下 dispatch 到主队列的任务不执行，而 UIScreen.mainScreen /
// _UICreateScreenUIImage 必须在主线程；1.7.0 就是这么 abort 进安全模式的。所以这里只走
// QuartzCore 的 CARenderServerCaptureDisplay（渲染服务器直出，任意线程可调）。
//
// 命令通道：SB_HOME_DIR/screen.cmd（root 侧写 /rootfs/private/var/... 同一文件）
//   shot            按点尺寸(默认 430x932)降采样输出
//   shot W H        指定点尺寸
//   shot raw        原像素不降采样
//   shotb64         额外落一份 base64 文本，方便 ssh 侧直接看
//   state / info    只回状态
// 输出：SB_HOME_DIR/shot.jpg（二进制 JPEG），日志一行 SCR shot ...
//
// 坐标约定：降采样后 1 图像像素 = 1 屏幕点，与 SBTouch 的点击坐标同一套（430x932 点）。

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

typedef CGImageRef (*SCRenderCapFn)(uint32_t serverPort, CFStringRef displayName, CFDictionaryRef options);

static SCRenderCapFn g_scCap = NULL;
static int      g_scCapTried = 0;
static int      g_scPtW = 430;      // 点宽（与 SBTouch 缺省一致）
static int      g_scPtH = 932;      // 点高
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

// ------------------------------------------------------------------ 捕获

static int scResolve(void) {
    if (g_scCapTried) return g_scCap != NULL;
    g_scCapTried = 1;

    void *qz = dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_LAZY);
    if (qz) {
        g_scCap = (SCRenderCapFn)dlsym(qz, "CARenderServerCaptureDisplay");
    }
    if (!g_scCap) {
        g_scCap = (SCRenderCapFn)dlsym(RTLD_DEFAULT, "CARenderServerCaptureDisplay");
    }
    SBLogSync("SCR cap sym=%d qz=%d", g_scCap ? 1 : 0, qz ? 1 : 0);
    return g_scCap != NULL;
}

// 返回 +1 引用，调用方负责 CGImageRelease
static CGImageRef scCapture(const char **srcOut) {
    if (!scResolve()) return NULL;

    const char *names[3] = { "LCD", "Main", "Display" };
    for (int i = 0; i < 3; i++) {
        CFStringRef nm = scCFStr(names[i]);
        if (!nm) continue;
        CGImageRef img = g_scCap(0, nm, NULL);
        CFRelease(nm);
        if (img) {
            if (srcOut) *srcOut = names[i];
            return img;
        }
        SBLogSync("SCR cap try %s = null", names[i]);
    }
    return NULL;
}

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

// ------------------------------------------------------------------ 编码 / 落盘

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

static int scDoShot(int tw, int th, int rawMode, int wantB64) {
    long t0 = scNowMs();
    const char *src = "(none)";
    CGImageRef srcImg = scCapture(&src);
    if (!srcImg) {
        g_scFails++;
        SBLogSync("SCR shot FAIL cap-sym=%d", g_scCap ? 1 : 0);
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
    SBLogSync("SCR shot src=%s px=%zux%zu -> pt=%zux%zu bytes=%ld file=%ld b64=%ld ms=%ld n=%d fail=%d",
              src, pw, ph, ow, oh,
              jpg ? (long)CFDataGetLength(jpg) : -1L,
              wrote, b64Len, scNowMs() - t0, g_scShots + 1, g_scFails);

    if (jpg) CFRelease(jpg);
    if (outImg) CGImageRelease(outImg);
    CGImageRelease(srcImg);
    g_scShots++;
    return (wrote > 0) ? 0 : -1;
}

static void scState(void) {
    SBLogSync("SCR state cap=%d tried=%d pt=%dx%d shots=%d fail=%d thread=%d",
              g_scCap ? 1 : 0, g_scCapTried, g_scPtW, g_scPtH, g_scShots, g_scFails, g_scThreadUp);
}

// 处理一行命令；返回 1 表示处理过
static int scHandleLine(char *line) {
    char *op = line;
    while (*op == ' ' || *op == '\t') op++;
    if (!*op) return 0;

    if (!strcmp(op, "state") || !strcmp(op, "info")) { scState(); return 1; }

    if (!strncmp(op, "shot", 4)) {
        int wantB64 = 0, raw = 0;
        int tw = 0, th = 0;
        char *rest = op + 4;
        while (*rest == ' ' || *rest == '\t') rest++;

        if (!strcmp(rest, "raw")) { raw = 1; }
        else if (!strcmp(rest, "b64") || !strcmp(rest, "base64")) { wantB64 = 1; }
        else if (rest[0]) {
            double a = 0, b = 0;
            if (sscanf(rest, "%lf %lf", &a, &b) == 2 && a > 0 && b > 0) {
                tw = (int)a; th = (int)b;
                g_scPtW = tw; g_scPtH = th;
            }
        }
        // shotb64 这种连写
        if (op[4] == 'b') wantB64 = 1;

        scDoShot(tw, th, raw, wantB64);
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
    char *line = NULL;
    while (fgets(buf, sizeof(buf), f)) {
        char *p = strchr(buf, '\n');
        if (p) *p = 0;
        p = strchr(buf, '\r');
        if (p) *p = 0;
        // 只取第一条非空命令
        char *s = buf;
        while (*s == ' ' || *s == '\t') s++;
        if (!*s) continue;
        scHandleLine(s);
        line = s;
        break;
    }
    fclose(f);

    // 读过即删，避免重复执行
    if (line) unlink(SC_CMD_FILE);
}

static void *scThreadMain(void *arg) {
    (void)arg;
    scMarker("thread-enter");
    scResolve();

    int tick = 0;
    while (1) {
        tick++;
        pthread_testcancel();
        if ((tick % 10) == 0) {
            // 300ms 量级轮询（10 轮 x 30ms）
            scPollOnce();
        }
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
    static char s[160];
    snprintf(s, sizeof(s), "cap=%d tried=%d pt=%dx%d shots=%d fail=%d",
             g_scCap ? 1 : 0, g_scCapTried, g_scPtW, g_scPtH, g_scShots, g_scFails);
    return s;
}

// 供其它模块（AI 侧）直接调用，不等命令文件
int SBScreenShotNow(int tw, int th, int wantB64) {
    return scDoShot(tw, th, 0, wantB64);
}
