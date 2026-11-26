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

typedef void (*SBNetFn)(void *ctx, id answer, id err);
void SBNetPost(id prompt, SBNetFn fn, void *ctx);

id SBAceAddViews(id text);
id SBAcePreSynthTTS(id text);

void *SBMakeNoopBlock(void);
BOOL SBSubmitInstall(void);
BOOL SBSubmitAce(id ace, id conn);

void SBProbeDump(void);
