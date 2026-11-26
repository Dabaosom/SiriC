#import "SiriBridge.h"

//  L1：先调原实现，再取文本。优先 AFConnection 入口（自带连接实例），兜底 delegate。

static SBTextFn g_textFn = NULL;
static IMP g_origRec = NULL;
static IMP g_origDel = NULL;

void SBSetTextFunc(SBTextFn fn) {
    g_textFn = fn;
}

//  L2：照逆向 0x1af20 —— SASRecognition → phrases → interpretations → tokens → text，
//  逐 token 取值并以空格拼接（唯一取文本路径，不加其它快捷方法）。
static NSString *SBTextFrom(id recognition) {
    if (!recognition) return nil;
    id phrases = SBHasSel(recognition, @"phrases")
        ? ((id (*)(id, SEL))objc_msgSend)(recognition, sel_registerName("phrases")) : nil;
    if (![phrases isKindOfClass:[NSArray class]]) return nil;

    NSMutableString *out = [NSMutableString string];
    for (id phrase in (NSArray *)phrases) {
        id interps = SBHasSel(phrase, @"interpretations")
            ? ((id (*)(id, SEL))objc_msgSend)(phrase, sel_registerName("interpretations")) : nil;
        if (![interps isKindOfClass:[NSArray class]]) continue;
        for (id interp in (NSArray *)interps) {
            id tokens = SBHasSel(interp, @"tokens")
                ? ((id (*)(id, SEL))objc_msgSend)(interp, sel_registerName("tokens")) : nil;
            if (![tokens isKindOfClass:[NSArray class]]) continue;
            for (id tok in (NSArray *)tokens) {
                id s = SBHasSel(tok, @"text")
                    ? ((id (*)(id, SEL))objc_msgSend)(tok, sel_registerName("text")) : nil;
                if ([s isKindOfClass:[NSString class]] && [s length]) [out appendFormat:@"%@ ", s];
            }
        }
    }
    return out.length ? [out stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceCharacterSet]] : nil;
}

#if SB_STAGE >= 2
// 纯 C runtime 内省：把 ivar / selector 名拼成一行
static void sbDumpClass(Class cls, const char *tag) {
    if (!cls) return;
    char buf[420];
    int n = 0;

    unsigned ivn = 0;
    Ivar *ivs = class_copyIvarList(cls, &ivn);
    n += snprintf(buf + n, (size_t)(sizeof buf - n), "%s ivars(%u):", tag, ivn);
    for (unsigned i = 0; i < ivn && n < 380; i++) {
        const char *nm = ivar_getName(ivs[i]);
        n += snprintf(buf + n, (size_t)(sizeof buf - n), " %s", nm ? nm : "?");
    }
    if (ivs) free(ivs);
    SBLog("%s", buf);

    unsigned mn = 0;
    Method *ms = class_copyMethodList(cls, &mn);
    n = 0;
    n += snprintf(buf + n, (size_t)(sizeof buf - n), "%s sels(%u):", tag, mn);
    for (unsigned i = 0; i < mn && n < 380; i++) {
        const char *nm = sel_getName(method_getName(ms[i]));
        n += snprintf(buf + n, (size_t)(sizeof buf - n), " %s", nm ? nm : "?");
    }
    if (ms) free(ms);
    SBLog("%s", buf);
}
#endif

static void sbRec(id self, SEL _cmd, id recognition) {
    if (g_origRec) ((void (*)(id, SEL, id))g_origRec)(self, _cmd, recognition);
#if SB_STAGE >= 2
    Class cls = object_getClass(recognition);
    SBLog("R2 cls=%s", cls ? class_getName(cls) : "(nil)");
    Method pm = cls ? class_getInstanceMethod(cls, sel_registerName("phrases")) : NULL;
    SBLog("R2 hasPhrases=%d", pm ? 1 : 0);
#if SB_STAGE >= 2
    sbDumpClass(cls, "DUMP");
#endif
    if (!pm) return;
    id phrases = ((id (*)(id, SEL))objc_msgSend)(recognition, sel_registerName("phrases"));
    SBLog("R2 phrases=%p", (void *)phrases);
    NSString *t = SBTextFrom(recognition);
    if (t.length) SBLog("R2 text=%lu", (unsigned long)t.length);
    if (t.length && g_textFn) g_textFn(t, self);
#else
    // S1：只证明 hook 命中，不碰任何 ObjC
    SBLog("RECOG hit recog=%p conn=%p", (void *)recognition, (void *)self);
#endif
}

static id SBConnectionFromIvars(id obj) {
    unsigned int n = 0;
    Ivar *ivars = class_copyIvarList(object_getClass(obj), &n);
    id found = nil;
    for (unsigned i = 0; i < n && !found; i++) {
        id v = object_getIvar(obj, ivars[i]);
        if (v && [NSStringFromClass(object_getClass(v)) isEqualToString:@"AFConnection"]) {
            found = v;
        }
    }
    free(ivars);
    return found;
}

static void sbDel(id self, SEL _cmd, id recognition) {
    if (g_origDel) ((void (*)(id, SEL, id))g_origDel)(self, _cmd, recognition);
#if SB_STAGE >= 2
    NSString *t = SBTextFrom(recognition);
    if (t.length && g_textFn) g_textFn(t, SBConnectionFromIvars(self));
#else
    SBLog("RECOG del hit recog=%p del=%p", (void *)recognition, (void *)self);
#endif
}

BOOL SBInstallRecognitionHook(Class connClass, Class delClass) {
    if (connClass) {
        Method m = class_getInstanceMethod(connClass,
                     sel_registerName("_tellSpeechDelegateSpeechRecognized:"));
        if (m) {
            g_origRec = method_getImplementation(m);
            method_setImplementation(m, (IMP)sbRec);
            SBLog("HOOK recog=AFConnection");
            return YES;
        }
        SBLog("HOOK recog missing on AFConnection");
    }
    if (delClass) {
        Method m = class_getInstanceMethod(delClass, sel_registerName("speechRecognized:"));
        if (m) {
            g_origDel = method_getImplementation(m);
            method_setImplementation(m, (IMP)sbDel);
            SBLog("HOOK recog=Delegate");
            return YES;
        }
    }
    return NO;
}
