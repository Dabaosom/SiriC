#import "SiriBridge.h"
#include <string.h>
#include <stdlib.h>
#include <dlfcn.h>

//  L2：原生意图交还 Siri，其余交给 AI。纯 C 比较，不建 ObjC 常量。
//  1.5.6：前缀表只能挡住「打开 / 播放」这类开头词，用户实测「用微信给某某发消息」
//  被当成 AI 问题答掉了 —— 这类句子的动作词不在句首。改为两条判据：
//    ① 句首是原生动作词（原表 + 「几点」）；
//    ② 句子里同时出现「已安装 App 的名字」+「动作动词」→ 判原生。
//  App 名单在首次判定时从 LSApplicationWorkspace 枚举一次并缓存，失败就退回①。

static const char *kNative[] = {
    "打开", "关掉", "关闭", "调高", "调低", "音量", "亮度", "闪光灯",
    "打电话", "拨打", "发短信", "发消息", "闹钟", "提醒我", "定时",
    "导航", "带我去", "播放", "暂停", "下一首", "上一首",
    "现在几点", "现在多少点", "今天几号", "天气", "附近",
    "几点", "几号",
    NULL
};

// 动作动词：只收两字及以上的，单字（发/查/搜）误伤太多，不入表。
static const char *kVerb[] = {
    "发送", "发给", "发一条", "发个", "发送给", "发消息", "发短信", "发邮件",
    "打电话", "拨号", "拨打", "视频通话", "语音通话",
    "打开", "关闭", "播放", "暂停", "搜索", "分享", "转账", "付款", "支付",
    "扫码", "叫车", "打车", "导航", "定位", "截图", "下载", "安装", "卸载",
    "点赞", "关注", "评论", "回复", "删除", "预约", "充值", "缴费", "记录",
    NULL
};

#define SB_MAXAPP 220
static char *g_apps[SB_MAXAPP];
static int g_appCount = -1;   // -1 未枚举，0 枚举失败

static void sbLoadApps(void) {
    if (g_appCount >= 0) return;
    g_appCount = 0;
    void *h = dlopen("/System/Library/PrivateFrameworks/MobileCoreServices.framework/MobileCoreServices",
                     RTLD_NOW);
    if (!h) h = dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_NOW);
    Class wc = objc_getClass("LSApplicationWorkspace");
    if (!wc) { SBLogSync("ROUTE apps: no LSApplicationWorkspace"); return; }
    id ws = SBMsgC((id)wc, "defaultWorkspace");
    if (!ws) { SBLogSync("ROUTE apps: no workspace"); return; }
    id apps = nil;
    if (SBHasSelC(ws, "allInstalledApplications")) apps = SBMsgC(ws, "allInstalledApplications");
    if (!apps && SBHasSelC(ws, "allApplications")) apps = SBMsgC(ws, "allApplications");
    if (!apps) { SBLogSync("ROUTE apps: none"); return; }

    id arr = apps;
    NSUInteger n = [arr count];
    SBLogSync("ROUTE apps: count=%lu", (unsigned long)n);
    for (NSUInteger i = 0; i < n && g_appCount < SB_MAXAPP; i++) {
        id px = [arr objectAtIndex:i];
        id nm = nil;
        if (SBHasSelC(px, "localizedName")) nm = SBMsgC(px, "localizedName");
        if (!nm) continue;
        const char *s = (const char *)SBMsgC(nm, "UTF8String");
        if (!s || strlen(s) < 2) continue;
        // 去重
        int dup = 0;
        for (int k = 0; k < g_appCount; k++) {
            if (!strcmp(g_apps[k], s)) { dup = 1; break; }
        }
        if (dup) continue;
        char *cp = strdup(s);
        if (cp) g_apps[g_appCount++] = cp;
    }
    SBLogSync("ROUTE apps: kept=%d", g_appCount);
}

// 语音识别结果会把唤醒词一起带回来（实测：`嘿Siri运行更换微信 `），
// 前缀比对必须先把这层剥掉，否则「运行 / 打开 / 执行」全都匹配不到，
// 句子会滑到 AI 分支；原生分支同样受影响，所以两边共用这一处。
const char *SBStripWake(const char *s) {
    if (!s) return s;
    while (*s == ' ' || *s == '\t' || *s == '\n' || *s == '\r') s++;
    // 嘿Siri / 嘿 Siri / 你好Siri / Hi Siri / HiSiri（大小写都认）
    if (strncmp(s, "嘿", strlen("嘿")) == 0) {
        s += strlen("嘿");
        while (*s == ' ' || *s == '\t') s++;
    } else if (!strncmp(s, "你好", strlen("你好"))) {
        s += strlen("你好");
        while (*s == ' ' || *s == '\t') s++;
    } else if (s[0] == 'H' || s[0] == 'h') {
        while (*s == ' ' || *s == '\t') s++;
    } else {
        while (*s == ' ' || *s == '\t') s++;
        return s;
    }
    // 剩下的 "Siri" / "siri" / "hi siri" 之类
    if ((s[0] == 'S' || s[0] == 's') && (s[1] == 'i' || s[1] == 'I')) {
        while (*s && *s != ' ' && *s != '\t' && *s != '，' && *s != ',') s++;
    }
    while (*s == ' ' || *s == '\t' || *s == '，' || *s == ',') s++;
    return s;
}

BOOL SBRouteNative(id text) {
    if (!text) return YES;
    const char *s = (const char *)SBMsgC(text, "UTF8String");
    if (!s || !*s) return YES;
    s = SBStripWake(s);
    if (!*s) return YES;

    for (int i = 0; kNative[i]; i++) {
        const char *p = kNative[i];
        size_t n = strlen(p);
        if (strncmp(s, p, n) == 0) {
            SBLog("ROUTE native %s", p);
            return YES;
        }
    }

    // ② App 名 + 动作动词
    sbLoadApps();
    if (g_appCount > 0) {
        for (int a = 0; a < g_appCount; a++) {
            const char *nm = g_apps[a];
            if (!strstr(s, nm)) continue;
            for (int v = 0; kVerb[v]; v++) {
                if (strstr(s, kVerb[v])) {
                    SBLog("ROUTE app %s verb %s", nm, kVerb[v]);
                    return YES;
                }
            }
            // 句首「用X」也算操作：用微信… / 用支付宝…
            if (strncmp(s, "用", strlen("用")) == 0 || strncmp(s, "拿", strlen("拿")) == 0) {
                SBLog("ROUTE app %s 用", nm);
                return YES;
            }
            break;
        }
    }
    return NO;
}
