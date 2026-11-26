//
//  SiriBridge.h
//  单进程最小插件：识别 → AI → ACE(AddViews/PreSynthesizeTTS) → 原生管线
//  不含任何窗口、悬浮球、面板、自绘控件。
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>

// 0=仅能力探测  1=识别落日志  2=网络落日志  3=提交显示  4=追加朗读
#ifndef SB_STAGE
#define SB_STAGE 3
#endif

void SBLogLine(NSString *fmt, ...);
#define SBLog(fmt, ...) SBLogLine(fmt, ##__VA_ARGS__)

BOOL SBHasClass(NSString *name);
BOOL SBHasSel(id obj, NSString *selName);
BOOL SBSet(id obj, NSString *selName, id value);
id SBNew(NSString *className);
NSString *SBUUID(void);

typedef void (*SBTextFn)(NSString *text, id conn);
void SBSetTextFunc(SBTextFn fn);
BOOL SBInstallRecognitionHook(Class connectionClass, Class delegateClass);

BOOL SBRouteNative(NSString *text);

typedef void (*SBNetFn)(void *ctx, NSString *answer, NSString *err);
void SBNetPost(NSString *prompt, SBNetFn fn, void *ctx);

id SBAceAddViews(NSString *text);
id SBAcePreSynthTTS(NSString *text);

BOOL SBSubmitInstall(void);
BOOL SBSubmitAce(id ace, id conn);
