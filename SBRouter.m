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
    "调高", "调低", "音量", "亮度", "闪光灯",
    "打电话", "拨打", "发短信", "发消息", "闹钟", "提醒我", "定时",
    "导航", "带我去", "播放", "暂停", "下一首", "上一首",
    "现在几点", "现在多少点", "今天几号", "天气", "附近",
    "几点", "几号",
    NULL
};

// 1.6.98：裸「打开 / 关闭」不再一票交系统。原来"打开"两个字就能把整句交给原生，
// 「打开通知」「打开微信的搜索」这类系统不认的说法一律变成一次静默 —— 用户眼里就是"没反应"。
// 现在只有在点明了开什么时才放行：句中含已安装 App 名（交给下面的 ②）或含系统对象。
static const char *kOpenVerb[] = { "打开", "关掉", "关闭", "开启", NULL };
static const char *kSysObj[] = {
    "设置", "控制中心", "通知中心", "蓝牙", "飞行模式", "勿扰", "专注模式",
    "个人热点", "无线局域网", "无线网络", "wi-fi", "wifi", "手电筒", "蜂窝",
    "数据流量", "低电量模式", "深色模式", "屏幕亮度", NULL
};

// 判定的理由：留给上层打一行 IRX 日志，出问题时能直接看出命中的是哪张表的哪一条
static char g_sbWhy[96];
static void sbWhySet(const char *w) {
    if (!w) { g_sbWhy[0] = 0; return; }
    snprintf(g_sbWhy, sizeof g_sbWhy, "%s", w);
}
const char *SBLastRouteWhy(void) { return g_sbWhy; }

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
static char *g_appIds[SB_MAXAPP];
static int g_appCount = -1;   // -1 未枚举，0 枚举失败
static void sbLoadApps(void);

// 1.6.7：AI 下发 {"action":"app","name":"微信"} 时要能真打开，
// 所以枚举时把 bundleIdentifier 一并缓存。
static int sbOpenAppImpl(const char *bundleId) {
    void *h = dlopen("/System/Library/PrivateFrameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_NOW);
    if (!h) h = dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_NOW);
    Class wc = objc_getClass("LSApplicationWorkspace");
    if (!wc) { SBLogSync("APP open: no workspace"); return 0; }
    id ws = SBMsgC((id)wc, "defaultWorkspace");
    if (!ws) return 0;
    BOOL ok = ((BOOL (*)(id, SEL, id))objc_msgSend)(ws,
        sel_registerName("openApplicationWithBundleID:"), SBStr(bundleId));
    SBLogSync("APP open %s ok=%d", bundleId, ok ? 1 : 0);
    return ok ? 1 : 0;
}

// 1.6.69：按 bundleId 直接打开。LSApplicationWorkspace 是唯一稳定入口，
// 名字匹配（localizedName）实测对「微信」miss，不能依赖。
BOOL SBOpenAppID(const char *bundleId) {
    if (!bundleId || !*bundleId) return NO;
    SBLogSync("APP open id %s", bundleId);
    return sbOpenAppImpl(bundleId);
}

BOOL SBOpenAppNamed(const char *name) {
    if (!name || !*name) return NO;
    sbLoadApps();
    for (int i = 0; i < g_appCount; i++) {
        if (!strcmp(g_apps[i], name) && g_appIds[i]) return sbOpenAppImpl(g_appIds[i]);
    }
    // 名字不完全一致时按包含关系兜底（“微信” → “微信”）
    const char *best = NULL;
    size_t bestLen = 0;
    for (int i = 0; i < g_appCount; i++) {
        size_t n = strlen(g_apps[i]);
        if (n > bestLen && strstr(name, g_apps[i])) { best = g_apps[i]; bestLen = n; }
    }
    if (best) {
        for (int i = 0; i < g_appCount; i++) if (!strcmp(g_apps[i], best)) return sbOpenAppImpl(g_appIds[i]);
    }
    SBLogSync("APP open miss %s", name);
    return NO;
}

BOOL SBOpenURLString(const char *url) {
    if (!url || !*url) return NO;
    // 1.6.8：模型给的地址里可能带中文（实测 apps.apple.com 链接里含「红果短剧」），
    // 未编码直接交给 NSURL 会在主线程上卡死。这里先把非 ASCII / 空格 / 引号做百分号编码。
    char enc[1024];
    size_t used = 0;
    for (size_t i = 0; url[i] && used + 4 < sizeof(enc); i++) {
        unsigned char c = (unsigned char)url[i];
        if (c <= 0x20 || c >= 0x7F || c == '"') {
            enc[used++] = '%';
            enc[used++] = (char)('0' + ((c >> 4) & 0xF));
            enc[used++] = (char)('0' + (c & 0xF));
        } else {
            enc[used++] = (char)c;
        }
    }
    enc[used] = 0;
    if (strncmp(enc, "http://", 7) != 0 && strncmp(enc, "https://", 8) != 0) {
        SBLogSync("URL skip scheme");
        return NO;
    }
    void *h = dlopen("/System/Library/PrivateFrameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_NOW);
    if (!h) h = dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_NOW);
    Class wc = objc_getClass("LSApplicationWorkspace");
    id ws = wc ? SBMsgC((id)wc, "defaultWorkspace") : nil;
    Class urlCls = objc_getClass("NSURL");
    id u = urlCls ? ((id (*)(id, SEL, id))objc_msgSend)((id)urlCls,
        sel_registerName("URLWithString:"), SBStr(enc)) : nil;
    if (!ws || !u) { SBLogSync("URL open miss"); return NO; }
    Class dictCls = objc_getClass("NSDictionary");
    id opts = dictCls ? SBMsgC((id)dictCls, "dictionary") : nil;
    SBLogSync("URL open begin len=%lu", (unsigned long)used);
    BOOL ok = ((BOOL (*)(id, SEL, id, id))objc_msgSend)(ws,
        sel_registerName("openURL:withOptions:"), u, opts);
    SBLogSync("URL open ok=%d", ok ? 1 : 0);
    return ok ? YES : NO;
}

// 1.6.70：按任意 scheme 打开（weixin:// 这类自定义 scheme）。
// 与 SBOpenURLString 的区别只有一处：不强制 http/https。
// 实测 LSApplicationWorkspace 的 openApplicationWithBundleID 对微信返回 ok=0，
// scheme 这条路历史上验证过能通（打开 apps.apple.com 成功）。
BOOL SBOpenSchemeURL(const char *url) {
    if (!url || !*url) return NO;
    dlopen("/System/Library/PrivateFrameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_NOW);
    Class wc = objc_getClass("LSApplicationWorkspace");
    id ws = wc ? SBMsgC((id)wc, "defaultWorkspace") : nil;
    Class urlCls = objc_getClass("NSURL");
    id u = urlCls ? ((id (*)(id, SEL, id))objc_msgSend)((id)urlCls,
        sel_registerName("URLWithString:"), SBStr(url)) : nil;
    if (!ws || !u) { SBLogSync("SCHEME miss %s", url); return NO; }
    Class dictCls = objc_getClass("NSDictionary");
    id opts = dictCls ? SBMsgC((id)dictCls, "dictionary") : nil;
    BOOL ok = ((BOOL (*)(id, SEL, id, id))objc_msgSend)(ws,
        sel_registerName("openURL:withOptions:"), u, opts);
    SBLogSync("SCHEME open %s ok=%d", url, ok ? 1 : 0);
    return ok ? YES : NO;
}

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
        id bid = SBHasSelC(px, "bundleIdentifier") ? SBMsgC(px, "bundleIdentifier") : nil;
        const char *bi = bid ? (const char *)SBMsgC(bid, "UTF8String") : NULL;
        char *cpId = bi ? strdup(bi) : NULL;
        if (cp) {
            g_apps[g_appCount] = cp;
            g_appIds[g_appCount] = cpId;
            g_appCount++;
        } 
    }
    SBLogSync("ROUTE apps: kept=%d", g_appCount);
}

static int sbCiAt(const char *s, const char *p) {
    size_t n = strlen(p);
    for (size_t i = 0; i < n; i++) {
        char a = s[i], b = p[i];
        if (a >= 'A' && a <= 'Z') a = (char)(a - 'A' + 'a');
        if (b >= 'A' && b <= 'Z') b = (char)(b - 'A' + 'a');
        if (a != b) return 0;
    }
    return 1;
}

static const char *sbSkipWs(const char *s) {
    while (*s == ' ' || *s == '\t' || *s == '\n' || *s == '\r' || *s == ',') s++;
    while ((unsigned char)s[0] == 0xEF && (unsigned char)s[1] == 0xBC && (unsigned char)s[2] == 0x8C) s += 3;
    return s;
}

// 语音识别结果会把唤醒词一起带回来（实测：`嘿Siri运行更换微信 `，中间没有空格），
// 这里按固定长度剥掉「嘿」+「Siri」，绝不能用“跳到空格”的写法——中文紧跟在 Siri 后面，
// 那样会把整句话一起吞掉（1.6.1 的 bug，导致语音唤醒时全部滑到原生分支）。
const char *SBStripWake(const char *s) {
    if (!s) return s;
    s = sbSkipWs(s);
    if (strncmp(s, "嘿", strlen("嘿")) == 0) {
        s += strlen("嘿");
    } else if (strncmp(s, "你好", strlen("你好")) == 0) {
        s += strlen("你好");
    } else if (sbCiAt(s, "hi")) {
        s += 2;
    } else if (sbCiAt(s, "hey")) {
        s += 3;
    }
    s = sbSkipWs(s);
    if (sbCiAt(s, "siri")) s += 4;
    s = sbSkipWs(s);
    return s;
}

BOOL SBRouteNative(id text) {
    if (!text) return YES;
    const char *s = (const char *)SBMsgC(text, "UTF8String");
    if (!s || !*s) return YES;
    s = SBStripWake(s);
    if (!*s) return YES;
    sbWhySet(NULL);

    for (int i = 0; kNative[i]; i++) {
        const char *p = kNative[i];
        size_t n = strlen(p);
        if (strncmp(s, p, n) == 0) {
            SBLog("ROUTE native %s", p);
            sbWhySet(p);
            return YES;
        }
    }

    // 裸「打开 / 关闭」：只说动词不点对象，不进原生
    for (int ov = 0; kOpenVerb[ov]; ov++) {
        size_t on = strlen(kOpenVerb[ov]);
        if (strncmp(s, kOpenVerb[ov], on) != 0) continue;
        for (int i = 0; kSysObj[i]; i++) {
            if (strstr(s + on, kSysObj[i]) || strstr(s, kSysObj[i])) {
                SBLog("ROUTE native open-sysobj %s", kSysObj[i]);
                sbWhySet(kSysObj[i]);
                return YES;
            }
        }
        // 没点明对象：交给下面 ② 的「App 名 + 动词」判据，判不出就进 AI
        break;
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
                    char b[96];
                    snprintf(b, sizeof b, "app:%s+%s", nm, kVerb[v]);
                    sbWhySet(b);
                    return YES;
                }
            }
            // 句首「用X」也算操作：用微信… / 用支付宝…
            if (strncmp(s, "用", strlen("用")) == 0 || strncmp(s, "拿", strlen("拿")) == 0) {
                SBLog("ROUTE app %s 用", nm);
                char b[96];
                snprintf(b, sizeof b, "app:%s+用", nm);
                sbWhySet(b);
                return YES;
            }
            break;
        }
    }
    return NO;
}

// 1.6.21：原生能力白名单 —— 系统自己能答的纯查询（时间、天气、日程、设备状态…），
// 不接管、不请求 AI，整句放行让 Siri 用真实数据作答。
// 原则是「宁可漏判给 AI，也不要把开放问题丢给系统变成网页搜索」，所以：
//   ① 必须命中某类关键词；② 出现开放提问特征（为什么/怎么/是什么/介绍/写/翻译…）一律排除。
static const char *kQTime[]  = { "几点", "几号", "星期几", "周几", "什么日子", "日期", "今天几", NULL };
// 1.6.98：通知是系统自己的一个完整域（设备上有 SiriNotificationsIntents + Notifications.siriUIBundle），
// 但我们原来的四张表里"通知"一个字都没有，所以「看通知/读通知」必然整句滑进 AI，
// AI 没有执行能力只能生成一段话 —— 这就是"看起来在搪塞"的来源。现在显式归到通知域。
static const char *kQNotify[] = { "通知", "未读", "消息提示", "新消息", "通知中心", "播报通知", NULL };
static const char *kQWeather[] = { "天气", "气温", "多少度", "下雨", "下雪", "带伞", "空气质量", "雾霾", "风力", NULL };
static const char *kQAgenda[] = { "日程", "安排", "待办", "提醒我", "闹钟", "计时器", "倒计时", "会议", "课表", NULL };
static const char *kQDevice[] = { "电量", "电池", "充电", "存储", "内存", "剩余空间", "信号", "网络", NULL };
static const char *kQComm[]   = { "打电话给", "拨给", "发短信给", "发消息给", "发微信给", "发个消息", NULL };
static const char *kQSys[]    = { "导航", "播放", "暂停", "音量", "亮度", "静音", "勿扰", "专注模式", NULL };
static const char *kQCalc[]   = { "等于多少", "换算", "折合", "乘以", "除以", "加上", "减去", NULL };

// 开放问题特征：出现任何一个都不交原生
static const char *kOpen[] = {
    "为什么", "怎么", "如何", "是什么", "什么区别", "区别", "原理", "介绍", "讲讲", "说说",
    "写", "帮我写", "翻译", "解释", "评价", "推荐", "建议", "怎么办", "好不好",
    NULL
};

static int sbHitAny(const char *s, const char **tab) {
    for (int i = 0; tab[i]; i++) if (strstr(s, tab[i])) return 1;
    return 0;
}

BOOL SBRouteNativeQuery(id text) {
    if (!text) return NO;
    const char *s = (const char *)SBMsgC(text, "UTF8String");
    if (!s || !*s) return NO;
    s = SBStripWake(s);
    if (!*s) return NO;
    if (strlen(s) > 40) return NO;          // 长句多半是开放问题
    sbWhySet(NULL);

    if (sbHitAny(s, kOpen)) return NO;

    const char *why = NULL;
    if (sbHitAny(s, kQNotify)) why = "notify";
    else if (sbHitAny(s, kQTime)) why = "time";
    else if (sbHitAny(s, kQWeather)) why = "weather";
    else if (sbHitAny(s, kQAgenda)) why = "agenda";
    else if (sbHitAny(s, kQDevice)) why = "device";
    else if (sbHitAny(s, kQComm)) why = "comm";
    else if (sbHitAny(s, kQSys)) why = "sys";
    else if (sbHitAny(s, kQCalc)) why = "calc";
    if (!why) return NO;

    SBLog("ROUTE query %s", why);
    sbWhySet(why);
    return YES;
}
