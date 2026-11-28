//
//  SiriBridge.h
//  单进程 SpringBoard 插件：识别 → AI → ACE(AddViews/PreSynthesizeTTS) → 原生管线
//
//  铁律（本轮实测）：本 dylib 内经编译期固化的 ObjC 常量（@"…"、@[]、@{}、
//  [NSXxx class]）在 RootHide 注入后 fixup 不生效，首次 msgSend 即 SIGBUS。
//  因此：类一律 objc_getClass，字符串 SBStr，数组 SBArr1，字典 SBDict2。
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>

// 1=识别命中(纯C)  2=取文本  3=网络  4=提交AddViews  5=追加TTS
#ifndef SB_STAGE
#define SB_STAGE 2
#endif

// 日志：纯 C，启动期亦可安全调用
void SBLogF(const char *fmt, ...);
#define SBLog(fmt, ...) SBLogF(fmt, ##__VA_ARGS__)
void SBLogSync(const char *fmt, ...);
void SBLogCrit(const char *fmt, ...);

// 运行时常量构造（禁止用编译器字面量）
id SBStr(const char *s);
id SBArr1(id o);
id SBDict2(id v1, id k1, id v2, id k2);
id SBMsgC(id obj, const char *sel);
BOOL SBClassIs(id o, const char *clsName);

BOOL SBHasClassC(const char *name);
BOOL SBHasSelC(id obj, const char *sel);
BOOL SBSetC(id obj, const char *sel, id value);
id SBNewC(const char *clsName);
id SBUUIDStr(void);

typedef void (*SBTextFn)(id text, id conn);
void SBSetTextFunc(SBTextFn fn);
BOOL SBInstallRecognitionHook(Class connectionClass, Class delegateClass);

BOOL SBRouteNative(id text);
BOOL SBRouteNativeQuery(id text);
const char *SBLastRouteWhy(void);
BOOL SBInterruptTry(const char *s);
void SBTurnOnScreen(BOOL v);
const char *SBStripWake(const char *s);
BOOL SBOpenAppNamed(const char *name);
// 1.6.69：按 bundleId 打开。名字匹配会 miss（实测「微信」未命中），id 是确定的。
BOOL SBOpenAppID(const char *bundleId);
BOOL SBOpenURLString(const char *url);
// 1.6.70：任意 scheme（weixin://）打开，不校验 http/https
BOOL SBOpenSchemeURL(const char *url);
void SBSayAsync(const char *text, id conn);

typedef void (*SBNetFn)(void *ctx, id answer, id err);
void SBNetPost(id prompt, SBNetFn fn, void *ctx);
id SBNetPostSync(id prompt, double timeoutSec, id *errOut);
// 1.6.10 流式：首句成型时由 SBNet 回调，SBCore 只提交 TTS 先开口；
// 收尾时用 SBNetSpokeLen 把已念过的前缀切掉，避免重复朗读。
void SBNetPartial(const char *text, void *ctx);
size_t SBNetSpokeLen(void);
unsigned long long SBNetElapsedMs(void);

id SBAceAddViews(id text);
id SBAceAddViewsSplit(id text, id speak);
id SBAceAddViewsSplitRef(id text, id speak, id ref);
id SBAceAddViewsPhase(id text, id speak, id ref, const char *phase);
id SBAcePreSynthTTS(id text);
id SBMessagesFor(id prompt);

void *SBMakeNoopBlock(void);
BOOL SBSubmitInstall(void);
BOOL SBSubmitAce(id ace, id conn);
BOOL SBSubmitAceNoFlush(id ace, id conn);

void SBProbeDump(void);

void SBSignalGuard(void);

void SBObserveInstall(void);
void SBSelfTestDump(const char *tag);
// 1.6.25：SpringBoard 自己可读写的固定目录（Library 是它的沙盒内路径，Documents 只对外部可见）
#define SB_HOME_DIR "/var/mobile/Library/SiriBridge"

BOOL SBAIPending(void);
void SBAISetPending(BOOL v);
void SBFlushHeldReply(void);
// 1.6.25：冷却窗 —— AI 答案已提交，但系统自己的回答可能晚几百毫秒才下发，
// 这段时间仍要吞，否则原生那句会叠在 AI 答案上；冷却期吞完立刻回执（不按住）。
void SBCoolStart(double secs);
BOOL SBCooling(void);
void SBNetCancel(void);
// 1.6.26：跨进程探针 —— 向 App 侧端口发一次 ping，结果走日志
void SBAppPingAsync(const char *why);
void SBAppIPCBoot(void);
void SBFsCmdBoot(void);
int  SBDoAct(const char *instruction, char *out, size_t outLen);
void SBAppHelloWatch(void);
// 1.6.31：按文字找控件（App 侧遍历视图树，只回报不点击）
void SBAppFindAsync(const char *kw);
void SBAppTapAsync(const char *kw);
// 1.6.69：一条完整动作命令（支持 seq: 多步）在 App 侧执行，结果只进日志
void SBAppActAsync(const char *cmd);
// 1.6.69：同步版本，返回 0 表示 App 真的应答了（用来判断微信是否已从挂起恢复）
int  SBAppActSync(const char *cmd, char *reply, size_t replyLen);
void SBTapProbe(void);
void SBTapWatchBB(void);
void SBAXCmdBoot(void);
void SBHidProbe(void);
void SBHidTap(double x, double y);const char *SBHidFront(void);
void SBHidFrontProbe(void);
void SBHidBksTap(double x, double y);
int  SBTapAt(double x, double y);
void SBTapOnce(double x, double y);
int SBShimSwallowCount(void);

void SBShortcutLoad(void);
void *SBShortcutLoadThreadMain(void *p);
id SBShortcutNamesCSV(void);
BOOL SBShortcutRunNamed(const char *name, id conn);
BOOL SBShortcutExists(const char *name);
BOOL SBShortcutTry(id text, id conn);

// ===== 1.7.0 系统级触摸（SpringBoard 内 IOHID 注入，对齐 ZXTouch 参数） =====
// senderID 由真实触摸事件学出，首次开机后需用户碰一下屏幕；未就绪时发包会直接跳过。
void SBTouchBoot(void);
int  SBTouchReady(void);                       // 1=client 与 senderID 都就绪
const char *SBTouchStatus(void);               // "sender=0x.. client=.. learn=.. scr=.."
int  SBTouchTap(double x, double y);           // 参数为点，也可直接传 0..1
int  SBTouchSwipe(double x1, double y1, double x2, double y2, int ms);
int  SBTouchLongPress(double x, double y, int ms);

// ===== 1.7.3 观察层（SBScreen：截图）=====
// 纯 QuartzCore（CARenderServerCaptureDisplay）+ ImageIO，不碰 UIKit/UIScreen，
// 降采样后 1 像素 = 1 点（与 SBTouch 点击坐标同一套）。命令走 screen.cmd：
//   shot / shot W H / shot raw / shotb64 / size W H / state
void SBScreenBoot(void);
const char *SBScreenStatus(void);              // "cap=.. tried=.. pt=430x932 shots=.. fail=.."
int  SBScreenShotNow(int tw, int th, int wantB64);   // 直接出图（0=成功写盘）

// ===== 1.7.5 观察层（SBAxis：AX 语义查询）=====
// 私有三件套：_AXSApplicationAccessibilitySetEnabled / _AXUIElementCreateAppElementWithPid /
// __AXSetRequestingClient + _AXOverrideRequestingClientType；命中走 AXUIElementCopyElementAtPosition。
// 命令走 ax.cmd：state / front / at X Y / tapat X Y，结果落 ax_out.json。
void SBAxisBoot(void);
const char *SBAxisStatus(void);                 // "active=.. client=.. q=.. hit=.. fail=.."
