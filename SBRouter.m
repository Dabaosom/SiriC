#import "SiriBridge.h"

//  L2：原生意图交还 Siri，其余交给 AI。调用方都释放对象，这里只做保守前缀匹配。

static NSArray *SBNativeKeys(void) {
    static NSArray *v = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        v = @[ @"打开", @"关掉", @"关闭", @"调高", @"调低", @"音量", @"亮度", @"闪光灯",
               @"打电话", @"拨打", @"发短信", @"发消息", @"闹钟", @"提醒我", @"定时",
               @"导航", @"带我去", @"播放", @"暂停", @"下一首", @"上一首",
               @"现在几点", @"今天几号", @"天气", @"附近" ];
    });
    return v;
}

BOOL SBRouteNative(NSString *text) {
    if (!text.length) return YES;
    NSString *t = [text stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    for (NSString *p in SBNativeKeys()) {
        if ([t hasPrefix:p]) { SBLog("ROUTE native %s", p.UTF8String); return YES; }
    }
    return NO;
}
