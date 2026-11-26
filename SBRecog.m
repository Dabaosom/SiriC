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

static void sbRec(id self, SEL _cmd, id recognition) {
    if (g_origRec) ((void (*)(id, SEL, id))g_origRec)(self, _cmd, recognition);
    NSString *t = SBTextFrom(recognition);
    if (t.length && g_textFn) g_textFn(t, self);
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
    NSString *t = SBTextFrom(recognition);
    if (t.length && g_textFn) g_textFn(t, SBConnectionFromIvars(self));
}

BOOL SBInstallRecognitionHook(Class connClass, Class delClass) {
    if (connClass) {
        Method m = class_getInstanceMethod(connClass,
                     sel_registerName("_tellSpeechDelegateSpeechRecognized:"));
        if (m) {
            g_origRec = method_getImplementation(m);
            method_setImplementation(m, (IMP)sbRec);
            SBLog(@"HOOK recog=AFConnection");
            return YES;
        }
        SBLog(@"HOOK recog missing on AFConnection");
    }
    if (delClass) {
        Method m = class_getInstanceMethod(delClass, sel_registerName("speechRecognized:"));
        if (m) {
            g_origDel = method_getImplementation(m);
            method_setImplementation(m, (IMP)sbDel);
            SBLog(@"HOOK recog=Delegate");
            return YES;
        }
    }
    return NO;
}
