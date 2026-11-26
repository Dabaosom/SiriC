#import "SiriBridge.h"

//  L1：先调原实现，再取文本。
//  证据（SASSpeechRecognized 的 selector 表）：af_bestTextInterpretation 是现成文本 getter；
//  recognition 指向 SASRecognition，那里才有 phrases→interpretations→tokens 链。

static SBTextFn g_textFn = NULL;
static IMP g_origRec = NULL;
static IMP g_origDel = NULL;

void SBSetTextFunc(SBTextFn fn) { g_textFn = fn; }

static id sbGet(id obj, const char *sel) {
    if (!obj) return nil;
    if (![obj respondsToSelector:sel_registerName(sel)]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(obj, sel_registerName(sel));
}

// SASRecognition → phrases → interpretations → tokens → text，空格拼接（逆向 0x1af20）
static NSString *SBTextFromRecognition(id rec) {
    if (!rec) return nil;
    id phrases = sbGet(rec, "phrases");
    if (![phrases isKindOfClass:[NSArray class]]) return nil;

    NSMutableString *out = [NSMutableString string];
    for (id phrase in (NSArray *)phrases) {
        id interps = sbGet(phrase, "interpretations");
        if (![interps isKindOfClass:[NSArray class]]) continue;
        for (id interp in (NSArray *)interps) {
            id tokens = sbGet(interp, "tokens");
            if (![tokens isKindOfClass:[NSArray class]]) continue;
            for (id tok in (NSArray *)tokens) {
                id s = sbGet(tok, "text");
                if ([s isKindOfClass:[NSString class]] && [(NSString *)s length]) {
                    [out appendFormat:@"%@ ", s];
                }
            }
        }
    }
    if (!out.length) return nil;
    return [out stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
}

// SASSpeechRecognized：先 bestTextInterpretation，再 recognition 链
static NSString *SBTextFrom(id recognized) {
    if (!recognized) return nil;

    SBLog("S3 try best");
    id best = sbGet(recognized, "af_bestTextInterpretation");
    SBLog("S3 best=%p", (void *)best);
    if ([best isKindOfClass:[NSString class]] && [(NSString *)best length]) return best;

    SBLog("S3 try recognition");
    id rec = sbGet(recognized, "recognition");
    SBLog("S3 rec=%p", (void *)rec);
    NSString *t = SBTextFromRecognition(rec);
    SBLog("S3 chainText=%lu", (unsigned long)t.length);
    return t;
}

static void sbRec(id self, SEL _cmd, id recognition) {
    if (g_origRec) ((void (*)(id, SEL, id))g_origRec)(self, _cmd, recognition);
#if SB_STAGE >= 2
    Class cls = object_getClass(recognition);
    SBLog("R2 cls=%s", cls ? class_getName(cls) : "(nil)");
    NSString *t = SBTextFrom(recognition);
    if (t.length) {
        SBLog("R2 text len=%lu", (unsigned long)t.length);
        if (g_textFn) g_textFn(t, self);
    }
#else
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
