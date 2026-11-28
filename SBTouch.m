// SBTouch.m — 1.7.0
// 系统级触摸注入（SpringBoard 内完成），参数组合对齐 ZXTouch(iOS 15–18 实证版)。
//
// 与前几版的三个致命差异（1.6.64 那版为什么点了没反应）：
//   1) parent 事件真正是 15 参：... eventMask, buttonMask, x,y,z,tip,barrel, range, isAbsolute, options
//      之前按 14 参调用，buttonMask 缺失导致后面整串错位（isAbsolute 被当成 x 传）。
//   2) senderID 不能用伪造常量。真值是 backboardd 认的"发件人"，只能从一条真实触摸事件里
//      用 IOHIDEventGetSenderID 学出来，并按「同一次开机」缓存到文件。
//   3) 坐标必须是 0..1 归一化，且每帧要补发"仍在屏上"的手指数，否则 tap 会被当成抖动。
//
// 线程模型：专用 pthread（自带 runloop）——创建 client、学 senderID、发包全在同一线程，
// 不占主线程、不依赖 dispatch_async（RootHide 下 dispatch_async_f 曾不执行）。

#import "SiriBridge.h"
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <mach/mach_time.h>
#import <dlfcn.h>
#import <pthread.h>
#import <sys/sysctl.h>
#import <sys/time.h>
#import <sys/stat.h>
#import <time.h>
#import <unistd.h>
#import <math.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>

#define TC_SENDER_FILE  SB_HOME_DIR "/touch_senderid.txt"
#define TC_CMD_FILE     SB_HOME_DIR "/touch.cmd"
#define TC_MAX_FINGER   20
#define TC_SLOT_NONE    0
#define TC_SLOT_VALID   1
#define TC_SLOT_NEXT    2

#define TC_FIELD_BASE       0xb0019   // kIOHIDEventFieldDigitizerDisplayIntegrated
#define TC_FIELD_BUILTIN    0x4       // kIOHIDEventFieldIsBuiltIn
#define TC_FIELD_EVENTMASK  0xb0007   // kIOHIDEventFieldDigitizerEventMask
#define TC_FIELD_RANGE      0xb0008   // kIOHIDEventFieldDigitizerRange
#define TC_FIELD_TOUCH      0xb0009   // kIOHIDEventFieldDigitizerTouch
#define TC_FIELD_MAJOR_R    0xb0014   // majorRadius
#define TC_FIELD_MINOR_R    0xb0015   // minorRadius

#define TC_EV_DIGITIZER     11        // kIOHIDEventTypeDigitizer

#define TC_MASK_DOWN        3         // Range|Touch
#define TC_MASK_MOVE        4         // Position
#define TC_MASK_UP          2         // Touch(0)

// ---------- 私有函数指针 ----------
typedef void *IOHIDEv;      // IOHIDEventRef
typedef void *IOHIDSys;     // IOHIDEventSystemClientRef

typedef IOHIDEv (*FnCreateDig)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
                               uint32_t, uint32_t, double, double, double, double, double,
                               uint32_t, uint32_t, uint32_t);
typedef IOHIDEv (*FnCreateFinger)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
                                  double, double, double, double, double,
                                  uint32_t, uint32_t, uint32_t);
typedef void (*FnAppend)(IOHIDEv, IOHIDEv);
typedef void (*FnSetInt)(IOHIDEv, uint32_t, int32_t);
typedef void (*FnSetFloat)(IOHIDEv, uint32_t, double);
typedef IOHIDSys (*FnSysCreate)(CFAllocatorRef);
typedef void (*FnSetSender)(IOHIDEv, uint64_t);
typedef uint64_t (*FnGetSender)(IOHIDEv);
typedef void (*FnDispatch)(IOHIDSys, IOHIDEv);
typedef void (*FnSchedule)(IOHIDSys, CFRunLoopRef, CFStringRef);
typedef void (*FnUnschedule)(IOHIDSys, CFRunLoopRef, CFStringRef);
typedef void (*FnRegisterCb)(IOHIDSys, void *, void *, void *);
typedef void (*FnUnregisterCb)(IOHIDSys);
typedef int (*FnGetType)(IOHIDEv);

static FnCreateDig      fCreateDig;
static FnCreateFinger   fCreateFinger;
static FnAppend         fAppend;
static FnSetInt         fSetInt;
static FnSetFloat       fSetFloat;
static FnSysCreate      fSysCreate;
static FnSetSender      fSetSender;
static FnGetSender      fGetSender;
static FnDispatch       fDispatch;
static FnSchedule       fSchedule;
static FnUnschedule     fUnschedule;
static FnRegisterCb     fRegisterCb;
static FnUnregisterCb   fUnregisterCb;
static FnGetType        fGetType;

static CFStringRef g_runMode;      // 运行时构造，"kCFRunLoopDefaultMode"
static IOHIDSys    g_dispCli;      // 发包用
static IOHIDSys    g_learnCli;     // 学 senderID 用
static volatile uint64_t g_senderID;
static volatile int      g_learning;
static volatile int      g_symOk;
static double g_scrW, g_scrH;

// 每根手指的上一帧状态：state / type / 原始入参坐标（点或 0..1，原样保留）
static int    g_slotSt[TC_MAX_FINGER];
static int    g_slotTy[TC_MAX_FINGER];
static double g_slotX[TC_MAX_FINGER];
static double g_slotY[TC_MAX_FINGER];

// ---------- 命令队列 ----------
typedef struct {
    int op;                 // 1=tap 2=swipe 3=long
    double x1, y1, x2, y2;
    int    ms;
} TCCmd;

#define TC_QCAP 16
static TCCmd g_q[TC_QCAP];
static int g_qHead, g_qTail;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  g_cond = PTHREAD_COND_INITIALIZER;
static volatile int g_booted;

static uint64_t tcNow(void) { return mach_absolute_time(); }

// 开机时刻（秒）；senderID 缓存的有效性判据
static long tcBootTime(void) {
    struct timeval tv;
    size_t len = sizeof tv;
    if (sysctlbyname("kern.boottime", &tv, &len, NULL, 0) == 0) return (long)tv.tv_sec;
    return 0;
}

// ---------- 屏幕尺寸 ----------
// 1.7.2：boot 期彻底不碰 UIKit。
// 教训链：1.7.0 在触摸线程调 +[UIScreen mainScreen] → UIKit 断言 → SpringBoard SIGABRT → 安全模式。
// 这里不再有任何 UIScreen 调用；尺寸由 touch.cmd 的 "size W H" 命令给，
// 没给就用 430x932（iPhone 15 Pro Max 级别）兜底，归一化比例够用。
static int g_scrTries;   // 占位，当前无用途

static double tcNormX(double px) {
    double n = (px > 1.0) ? px / (g_scrW > 100 ? g_scrW : 430.0) : px;
    if (n < 0.002) n = 0.002;
    if (n > 0.998) n = 0.998;
    return n;
}
static double tcNormY(double py) {
    double n = (py > 1.0) ? py / (g_scrH > 100 ? g_scrH : 932.0) : py;
    if (n < 0.002) n = 0.002;
    if (n > 0.998) n = 0.998;
    return n;
}

// boot 落盘标记：纯 C，fopen/fflush 直写 —— 崩了也能证明"这个包到底有没有被加载"
static void tcMarker(const char *tag) {
    FILE *f = fopen(SB_HOME_DIR "/tc_boot.txt", "a");
    if (!f) return;
    fprintf(f, "%ld %s\n", (long)time(NULL), tag);
    fflush(f);
    fclose(f);
}
// ---------- 符号解析 ----------
// IOKit 一定被 SpringBoard 加载；万一 dlsym(RTLD_DEFAULT) 拿不到，显式 dlopen 再试一次。
static void *g_iokit;
static void *tcSym(const char *n) {
    void *p = dlsym(RTLD_DEFAULT, n);
    if (p) return p;
    if (!g_iokit) g_iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (g_iokit) return dlsym(g_iokit, n);
    return NULL;
}

static int tcResolve(void) {
    fCreateDig    = (FnCreateDig)tcSym("IOHIDEventCreateDigitizerEvent");
    fCreateFinger = (FnCreateFinger)tcSym("IOHIDEventCreateDigitizerFingerEvent");
    fAppend       = (FnAppend)tcSym("IOHIDEventAppendEvent");
    fSetInt       = (FnSetInt)tcSym("IOHIDEventSetIntegerValue");
    fSetFloat     = (FnSetFloat)tcSym("IOHIDEventSetFloatValue");
    fSysCreate    = (FnSysCreate)tcSym("IOHIDEventSystemClientCreate");
    fSetSender    = (FnSetSender)tcSym("IOHIDEventSetSenderID");
    fGetSender    = (FnGetSender)tcSym("IOHIDEventGetSenderID");
    fDispatch     = (FnDispatch)tcSym("IOHIDEventSystemClientDispatchEvent");
    fSchedule     = (FnSchedule)tcSym("IOHIDEventSystemClientScheduleWithRunLoop");
    fUnschedule   = (FnUnschedule)tcSym("IOHIDEventSystemClientUnscheduleWithRunLoop");
    fRegisterCb   = (FnRegisterCb)tcSym("IOHIDEventSystemClientRegisterEventCallback");
    fUnregisterCb = (FnUnregisterCb)tcSym("IOHIDEventSystemClientUnregisterEventCallback");
    fGetType      = (FnGetType)tcSym("IOHIDEventGetType");

    int ok = (fCreateDig && fCreateFinger && fAppend && fSetInt && fSetFloat &&
              fSysCreate && fSetSender && fGetSender && fDispatch) ? 1 : 0;
    SBLogSync("TC sym %s dig=%d finger=%d append=%d si=%d sf=%d sys=%d ss=%d gs=%d disp=%d sched=%d reg=%d",
              ok ? "base-ok" : "base-MISS",
              fCreateDig ? 1 : 0, fCreateFinger ? 1 : 0, fAppend ? 1 : 0,
              fSetInt ? 1 : 0, fSetFloat ? 1 : 0, fSysCreate ? 1 : 0,
              fSetSender ? 1 : 0, fGetSender ? 1 : 0, fDispatch ? 1 : 0,
              fSchedule ? 1 : 0, fRegisterCb ? 1 : 0);
    return ok;
}

// ---------- senderID 缓存 ----------
static uint64_t tcLoadSender(void) {
    FILE *f = fopen(TC_SENDER_FILE, "r");
    if (!f) return 0;
    long bt = 0;
    unsigned long long sid = 0;
    int n = fscanf(f, "%ld %llx", &bt, &sid);
    fclose(f);
    if (n != 2) { SBLogSync("TC sid file bad"); return 0; }
    long cur = tcBootTime();
    if (cur && labs(cur - bt) > 3) { SBLogSync("TC sid stale boot %ld vs %ld", bt, cur); return 0; }
    SBLogSync("TC sid loaded 0x%llx (boot %ld)", sid, bt);
    return (uint64_t)sid;
}

static void tcSaveSender(uint64_t sid) {
    FILE *f = fopen(TC_SENDER_FILE, "w");
    if (!f) { SBLogSync("TC sid save FAIL"); return; }
    fprintf(f, "%ld %llx\n", tcBootTime(), (unsigned long long)sid);
    fclose(f);
    chmod(TC_SENDER_FILE, 0644);
    SBLogSync("TC sid saved 0x%llx", (unsigned long long)sid);
}

// ---------- 事件构造 ----------
static IOHIDEv tcMakeParent(void) {
    if (!fCreateDig) return NULL;
    IOHIDEv p = fCreateDig(kCFAllocatorDefault, tcNow(),
                           3,    // transducer type: hand
                           99,   // index
                           1,    // identity
                           0,    // eventMask
                           0,    // buttonMask
                           0.0, 0.0, 0.0, 0.0, 0.0,
                           0,    // range
                           0,    // isAbsolute
                           0);   // options
    if (!p) return NULL;
    if (fSetInt) {
        fSetInt(p, TC_FIELD_BASE, 1);      // displayIntegrated
        fSetInt(p, TC_FIELD_BUILTIN, 1);   // built-in
    }
    return p;
}

static IOHIDEv tcMakeFinger(int idx, int mask, double nx, double ny, int range, int touch) {
    if (!fCreateFinger) return NULL;
    IOHIDEv c = fCreateFinger(kCFAllocatorDefault, tcNow(),
                              (uint32_t)idx,
                              3,                    // identity（固定 3，与 ZXTouch 一致）
                              (uint32_t)mask,
                              nx, ny, 0.0, 0.0, 0.0,
                              (uint32_t)range, (uint32_t)touch, 0);
    if (c && fSetFloat) {
        fSetFloat(c, TC_FIELD_MAJOR_R, 0.04f);
        fSetFloat(c, TC_FIELD_MINOR_R, 0.04f);
    }
    return c;
}

// 每帧：追加本帧事件 + 补发"仍在屏上"的手指，再补齐父事件字段并投递
static int tcFrame(int idx, int type, double px, double py) {
    if (!g_dispCli || !fDispatch) return -10;
    if (!g_senderID) { SBLogSync("TC frame skip: sender=0"); return -11; }

    double nx = tcNormX(px), ny = tcNormY(py);
    IOHIDEv parent = tcMakeParent();
    if (!parent) return -12;

    int mask = (type == 1) ? TC_MASK_DOWN : (type == 2 ? TC_MASK_MOVE : TC_MASK_UP);
    int rng  = (type == 3) ? 0 : 1;
    int tch  = (type == 3) ? 0 : 1;

    IOHIDEv child = tcMakeFinger(idx, mask, nx, ny, rng, tch);
    if (child) { fAppend(parent, child); CFRelease((CFTypeRef)child); }

    // 本指状态更新（坐标按原始入参保存，补发时原样再归一化）
    if (type == 3) {
        g_slotSt[idx] = TC_SLOT_NONE;
    } else {
        g_slotSt[idx] = TC_SLOT_NEXT;
        g_slotTy[idx] = type;
        g_slotX[idx]  = px;
        g_slotY[idx]  = py;
    }

    // 补发其他"仍在屏上"的手指
    for (int i = 0; i < TC_MAX_FINGER; i++) {
        if (i == idx) {
            if (g_slotSt[i] == TC_SLOT_NEXT) g_slotSt[i] = TC_SLOT_VALID;
            continue;
        }
        int st = g_slotSt[i];
        if (st == TC_SLOT_VALID) {
            int m2 = (g_slotTy[i] == 1) ? TC_MASK_DOWN : TC_MASK_MOVE;
            IOHIDEv c2 = tcMakeFinger(i, m2, tcNormX(g_slotX[i]), tcNormY(g_slotY[i]), 1, 1);
            if (c2) { fAppend(parent, c2); CFRelease((CFTypeRef)c2); }
        } else if (st == TC_SLOT_NEXT) {
            g_slotSt[i] = TC_SLOT_VALID;
        }
    }

    if (fSetInt) {
        fSetInt(parent, TC_FIELD_EVENTMASK, 0x23);
        fSetInt(parent, TC_FIELD_RANGE, 1);
        fSetInt(parent, TC_FIELD_TOUCH, 1);
    }
    fSetSender(parent, g_senderID);
    fDispatch(g_dispCli, parent);
    CFRelease((CFTypeRef)parent);
    return 0;
}

// ---------- v2：按参考实现的典型构造（parent mask=帧mask、touch=1、index/identity=0） ----------
static int tcFrame2(int idx, int type, double px, double py) {
    if (!g_dispCli || !fDispatch) return -10;
    if (!g_senderID) { SBLogSync("TC f2 skip: sender=0"); return -11; }

    int mask = (type == 1) ? TC_MASK_DOWN : (type == 2 ? TC_MASK_MOVE : TC_MASK_UP);
    int rng  = (type == 3) ? 0 : 1;
    int tch  = (type == 3) ? 0 : 1;

    IOHIDEv parent = fCreateDig(kCFAllocatorDefault, tcNow(),
                                3, 0, 0, (uint32_t)mask, 0,
                                0.0, 0.0, 0.0, 0.0, 0.0,
                                (uint32_t)rng, (uint32_t)tch, 0);
    if (!parent) return -12;
    if (fSetInt) {
        fSetInt(parent, TC_FIELD_BASE, 1);
        fSetInt(parent, TC_FIELD_BUILTIN, 1);
    }
    IOHIDEv child = tcMakeFinger(idx, mask, tcNormX(px), tcNormY(py), rng, tch);
    if (child) { fAppend(parent, child); CFRelease((CFTypeRef)child); }

    fSetSender(parent, g_senderID);
    fDispatch(g_dispCli, parent);
    CFRelease((CFTypeRef)parent);
    return 0;
}

static int tcDoSwipe2(double x1, double y1, double x2, double y2, int ms) {
    if (ms < 60) ms = 60;
    int steps = ms / 16;
    if (steps < 4) steps = 4;
    if (steps > 40) steps = 40;
    int per = ms / steps;
    if (per < 8) per = 8;
    int rc = tcFrame2(0, 1, x1, y1);
    if (rc) return rc;
    usleep(50000);                      // DOWN 后留握持时间
    for (int i = 1; i <= steps; i++) {
        double t = (double)i / (double)steps;
        rc = tcFrame2(0, 2, x1 + (x2 - x1) * t, y1 + (y2 - y1) * t);
        if (rc) return rc;
        usleep(per * 1000);
    }
    usleep(30000);
    return tcFrame2(0, 3, x2, y2);
}

// ---------- 手势 ----------
static int tcDoTap(double x, double y) {
    int rc = tcFrame(0, 1, x, y);
    usleep(30000);
    if (rc == 0) rc = tcFrame(0, 2, x, y);
    usleep(30000);
    if (rc == 0) rc = tcFrame(0, 3, x, y);
    return rc;
}

static int tcDoSwipe(double x1, double y1, double x2, double y2, int ms) {
    if (ms < 60) ms = 60;
    int steps = ms / 16;
    if (steps < 4) steps = 4;
    if (steps > 40) steps = 40;
    int rc = tcFrame(0, 1, x1, y1);
    if (rc) return rc;
    int per = ms / steps;
    if (per < 8) per = 8;
    for (int i = 1; i <= steps; i++) {
        usleep(per * 1000);
        double t = (double)i / (double)steps;
        double xi = x1 + (x2 - x1) * t;
        double yi = y1 + (y2 - y1) * t;
        rc = tcFrame(0, 2, xi, yi);
        if (rc) return rc;
    }
    usleep(per * 1000);
    return tcFrame(0, 3, x2, y2);
}

static int tcDoLong(double x, double y, int ms) {
    if (ms < 200) ms = 200;
    int rc = tcFrame(0, 1, x, y);
    if (rc) return rc;
    int frames = ms / 100;
    if (frames < 2) frames = 2;
    if (frames > 60) frames = 60;
    for (int i = 0; i < frames; i++) {
        usleep(100000);
        rc = tcFrame(0, 2, x, y);
        if (rc) return rc;
    }
    return tcFrame(0, 3, x, y);
}

// ---------- 学 senderID ----------
static void tcLearnCallback(void *target, void *refcon, void *service, IOHIDEv event) {
    (void)target; (void)refcon; (void)service;
    if (!event || !fGetType || !fGetSender) return;
    int t = fGetType(event);
    // 前 8 条把类型打全，方便真机上确认 digitizer 的实际枚举值
    static int logged;
    if (logged < 8) { logged++; SBLogSync("TC learn ev type=%d", t); }
    if (t != TC_EV_DIGITIZER) return;
    if (g_senderID) return;
    uint64_t sid = fGetSender(event);
    if (!sid) return;
    g_senderID = sid;
    SBLogSync("TC sid learned 0x%llx", (unsigned long long)sid);
}

static void tcStartLearn(void) {
    if (!fSysCreate || !fSchedule || !fRegisterCb) {
        SBLogSync("TC learn unavailable (no sched/reg)");
        return;
    }
    g_learnCli = fSysCreate(kCFAllocatorDefault);
    if (!g_learnCli) { SBLogSync("TC learn client NULL"); return; }
    fSchedule(g_learnCli, CFRunLoopGetCurrent(), g_runMode);
    fRegisterCb(g_learnCli, (void *)tcLearnCallback, NULL, NULL);
    g_learning = 1;
    SBLogSync("TC learn waiting: 请用手指碰一下屏幕");
}

static void tcStopLearn(void) {
    if (!g_learnCli) return;
    if (fUnregisterCb) fUnregisterCb(g_learnCli);
    if (fUnschedule) fUnschedule(g_learnCli, CFRunLoopGetCurrent(), g_runMode);
    g_learning = 0;
    SBLogSync("TC learn done");
}

// ---------- 命令文件（免重编译的真机试验通道） ----------
static void tcPollCmdFile(void) {
    FILE *f = fopen(TC_CMD_FILE, "r");
    if (!f) return;
    char line[128] = {0};
    if (fgets(line, sizeof line, f) == NULL) { fclose(f); unlink(TC_CMD_FILE); return; }
    fclose(f);
    unlink(TC_CMD_FILE);

    char op[16] = {0};
    double a = 0, b = 0, c = 0, d = 0;
    int ms = 0;
    if (sscanf(line, "%15s", op) != 1) { SBLogSync("TC cmd bad: %s", line); return; }

    if (!strcmp(op, "state") || !strcmp(op, "probe")) {
        SBLogSync("TC %s sender=0x%llx client=%p scr=%.0fx%.0f learn=%d",
                  op, (unsigned long long)g_senderID, g_dispCli, g_scrW, g_scrH, g_learning);
        return;
    }
    if (!strcmp(op, "size")) {
        if (sscanf(line, "%*s %lf %lf", &a, &b) != 2) { SBLogSync("TC size bad: %s", line); return; }
        if (a > 100 && b > 100) { g_scrW = a; g_scrH = b; }
        SBLogSync("TC size set %.0fx%.0f", g_scrW, g_scrH);
        return;
    }
    if (!strcmp(op, "tap")) {
        if (sscanf(line, "%*s %lf %lf", &a, &b) != 2) { SBLogSync("TC tap bad: %s", line); return; }
        int rc = tcDoTap(a, b);
        SBLogSync("TC tap %.0f,%.0f rc=%d", a, b, rc);
        return;
    }
    if (!strcmp(op, "swipe")) {
        if (sscanf(line, "%*s %lf %lf %lf %lf %d", &a, &b, &c, &d, &ms) < 4) {
            SBLogSync("TC swipe bad: %s", line);
            return;
        }
        if (ms <= 0) ms = 300;
        int rc = tcDoSwipe(a, b, c, d, ms);
        SBLogSync("TC swipe %.0f,%.0f -> %.0f,%.0f %dms rc=%d", a, b, c, d, ms, rc);
        return;
    }
    if (!strcmp(op, "swipe2")) {
        if (sscanf(line, "%*s %lf %lf %lf %lf %d", &a, &b, &c, &d, &ms) < 4) {
            SBLogSync("TC swipe2 bad: %s", line);
            return;
        }
        if (ms <= 0) ms = 400;
        int rc = tcDoSwipe2(a, b, c, d, ms);
        SBLogSync("TC swipe2 %.0f,%.0f -> %.0f,%.0f %dms rc=%d", a, b, c, d, ms, rc);
        return;
    }
    if (!strcmp(op, "long") || !strcmp(op, "hold")) {
        if (sscanf(line, "%*s %lf %lf %d", &a, &b, &ms) < 2) { SBLogSync("TC long bad: %s", line); return; }
        if (ms <= 0) ms = 700;
        int rc = tcDoLong(a, b, ms);
        SBLogSync("TC long %.0f,%.0f %dms rc=%d", a, b, ms, rc);
        return;
    }
    SBLogSync("TC cmd unknown: %s", line);
}

// ---------- 线程主 ----------
static void *tcThreadMain(void *p) {
    (void)p;
    SBLogSync("TC thread start");

    if (!g_runMode) {
        g_runMode = CFStringCreateWithCString(kCFAllocatorDefault, "kCFRunLoopDefaultMode",
                                              kCFStringEncodingUTF8);
    }
    g_symOk = tcResolve();
    SBLogSync("TC scr at start=%.0fx%.0f", g_scrW, g_scrH);
    if (!g_symOk) { SBLogSync("TC abort: missing IOHID symbols"); return NULL; }

    g_senderID = tcLoadSender();
    g_dispCli = fSysCreate(kCFAllocatorDefault);
    SBLogSync("TC disp client=%p", g_dispCli);
    if (!g_dispCli) return NULL;

    if (!g_senderID) tcStartLearn();

    int tick = 0;
    for (;;) {
        // 学 senderID 期间跑一下 runloop，回调才可能触发
        if (g_learning) {
            if (g_senderID) { tcStopLearn(); tcSaveSender(g_senderID); }
            else CFRunLoopRunInMode(g_runMode, 0.05, true);
        }

        // 取命令
        TCCmd cmd;
        int have = 0;
        pthread_mutex_lock(&g_lock);
        if (g_qTail != g_qHead) {
            cmd = g_q[g_qTail];
            g_qTail = (g_qTail + 1) % TC_QCAP;
            have = 1;
        }
        pthread_mutex_unlock(&g_lock);

        if (have) {
            int rc = -1;
            if (cmd.op == 1) rc = tcDoTap(cmd.x1, cmd.y1);
            else if (cmd.op == 2) rc = tcDoSwipe(cmd.x1, cmd.y1, cmd.x2, cmd.y2, cmd.ms);
            else if (cmd.op == 3) rc = tcDoLong(cmd.x1, cmd.y1, cmd.ms);
            SBLogSync("TC exec op=%d rc=%d", cmd.op, rc);
            continue;
        }

        // 每 ~300ms 看一次命令文件
        if ((++tick % 30) == 0) tcPollCmdFile();
        usleep(10000);
    }
    return NULL;
}

// ---------- 对外 ----------
void SBTouchBoot(void) {
    if (g_booted) return;
    g_booted = 1;
    // 先落盘：哪怕下一秒崩，也能从 tc_boot.txt 看出这个包被加载过
    tcMarker("boot-enter");
    if (!g_runMode) {
        g_runMode = CFStringCreateWithCString(kCFAllocatorDefault, "kCFRunLoopDefaultMode",
                                              kCFStringEncodingUTF8);
    }
    SBLogSync("TC boot enter (scr=%.0fx%.0f, size via touch.cmd size W H)", g_scrW, g_scrH);

    pthread_t th;
    if (pthread_create(&th, NULL, tcThreadMain, NULL) == 0) {
        pthread_detach(th);
        tcMarker("thread-spawned");
    } else {
        SBLogSync("TC thread create FAIL");
        tcMarker("thread-fail");
    }
}

int SBTouchReady(void) {
    return (g_dispCli && g_senderID) ? 1 : 0;
}

const char *SBTouchStatus(void) {
    static char out[128];
    snprintf(out, sizeof out, "sender=0x%llx client=%d learn=%d scr=%.0fx%.0f",
             (unsigned long long)g_senderID, g_dispCli ? 1 : 0, g_learning, g_scrW, g_scrH);
    return out;
}

static int tcEnqueue(TCCmd c) {
    int rc = 0;
    pthread_mutex_lock(&g_lock);
    int next = (g_qHead + 1) % TC_QCAP;
    if (next == g_qTail) rc = -1;          // 满
    else { g_q[g_qHead] = c; g_qHead = next; }
    pthread_mutex_unlock(&g_lock);
    if (rc) SBLogSync("TC queue full");
    return rc;
}

int SBTouchTap(double x, double y) {
    TCCmd c; memset(&c, 0, sizeof c);
    c.op = 1; c.x1 = x; c.y1 = y;
    return tcEnqueue(c);
}

int SBTouchSwipe(double x1, double y1, double x2, double y2, int ms) {
    TCCmd c; memset(&c, 0, sizeof c);
    c.op = 2; c.x1 = x1; c.y1 = y1; c.x2 = x2; c.y2 = y2; c.ms = ms;
    return tcEnqueue(c);
}

int SBTouchLongPress(double x, double y, int ms) {
    TCCmd c; memset(&c, 0, sizeof c);
    c.op = 3; c.x1 = x; c.y1 = y; c.ms = ms;
    return tcEnqueue(c);
}
