#import "SiriBridge.h"
#include <string.h>

//  L2：原生意图交还 Siri，其余交给 AI。纯 C 比较，不建 ObjC 常量。

static const char *kNative[] = {
    "打开", "关掉", "关闭", "调高", "调低", "音量", "亮度", "闪光灯",
    "打电话", "拨打", "发短信", "发消息", "闹钟", "提醒我", "定时",
    "导航", "带我去", "播放", "暂停", "下一首", "上一首",
    "现在几点", "今天几号", "天气", "附近",
    NULL
};

BOOL SBRouteNative(id text) {
    if (!text) return YES;
    const char *s = (const char *)SBMsgC(text, "UTF8String");
    if (!s || !*s) return YES;
    while (*s == ' ' || *s == '\t' || *s == '\n' || *s == '\r') s++;
    if (!*s) return YES;

    for (int i = 0; kNative[i]; i++) {
        const char *p = kNative[i];
        size_t n = strlen(p);
        if (strncmp(s, p, n) == 0) {
            SBLog("ROUTE native %s", p);
            return YES;
        }
    }
    return NO;
}
