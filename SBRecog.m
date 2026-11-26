#import "SiriBridge.h"
#include <string.h>

//  L1：先调原实现，再取文本。
//  SASSpeechRecognized 上有 af_bestTextInterpretation；其 recognition 指向 SASRecognition，
//  那里才有 phrases→interpretations→tokens→text（逆向 0x1af20，空格拼接）。

static SBTextFn g_textFn = NULL;
static IMP g_origRec = NULL;
static IMP g_origDel = NULL;

void SBSetTextFunc(SBTextFn fn) { g_textFn = fn; }

static id sbGet(id obj, const char *sel) {
    if (!obj) return nil;
    if (!SBHasSelC(obj, sel)) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(obj, sel_registerName(sel));
}

static unsigned long sbCount(id arr) {
    if (!SBClassIs(arr, "NSArray")) return 0;
    return ((unsigned long (*)(id, SEL))objc_msgSend)(arr, sel_registerName("count"));
}

static id sbAt(id arr, unsigned long i) {
    return ((id (*)(id, SEL, unsigned long))objc_msgSend)(arr, sel_registerName("objectAtIndex:"), i);
}

// SASRecognition → phrases → interpretations → tokens → text，空格拼接
static id SBTextFromRecognition(id rec) {
    if (!rec) return nil;
    id phrases = sbGet(rec, "phrases");
    unsigned long np = sbCount(phrases);
    if (!np) return nil;

    Class msCls = objc_getClass("NSMutableString");
    id out = ((id (*)(id, SEL))objc_msgSend)((id)msCls, sel_registerName("string"));
    BOOL first = YES;

    for (unsigned long i = 0; i < np; i++) {
        id phrase = sbAt(phrases, i);
        id interps = sbGet(phrase, "interpretations");
        unsigned long ni = sbCount(interps);
        for (unsigned long j = 0; j < ni; j++) {
            id interp = sbAt(interps, j);
            id tokens = sbGet(interp, "tokens");
            unsigned long nt = sbCount(tokens);
            for (unsigned long k = 0; k < nt; k++) {
                id tok = sbAt(tokens, k);
                id s = sbGet(tok, "text");
                const char *cs = s ? (const char *)SBMsgC(s, "UTF8String") : NULL;
                if (!cs || !*cs) continue;
                if (!first) ((void (*)(id, SEL, id))objc_msgSend)(
                    out, sel_registerName("appendString:"), SBStr(" "));
                ((void (*)(id, SEL, id))objc_msgSend)(
                    out, sel_registerName("appendString:"), s);
                first = NO;
            }
        }
    }
    if (first) return nil;
    return out;
}

static id SBTextFrom(id recognized) {
    if (!recognized) return nil;

    SBLog("S3 try best");
    id best = sbGet(recognized, "af_bestTextInterpretation");
    SBLog("S3 best=%p", (void *)best);
    if (SBClassIs(best, "NSString")) {
        const char *b = (const char *)SBMsgC(best, "UTF8String");
        if (b && *b) return best;
    }

    SBLog("S3 try recognition");
    id rec = sbGet(recognized, "recognition");
    SBLog("S3 rec=%p", (void *)rec);
    id t = SBTextFromRecognition(rec);
    SBLog("S3 chain=%p", (void *)t);
    return t;
}

static void sbRec(id self, SEL _cmd, id recognition) {
    if (g_origRec) ((void (*)(id, SEL, id))g_origRec)(self, _cmd, recognition);
#if SB_STAGE >= 2
    Class cls = object_getClass(recognition);
    SBLog("R2 cls=%s", cls ? class_getName(cls) : "(nil)");
    id t = SBTextFrom(recognition);
    if (t && g_textFn) {
        const char *cs = (const char *)SBMsgC(t, "UTF8String");
        SBLogSync("R2 text len=%lu", cs ? (unsigned long)strlen(cs) : 0UL);
#if SB_STAGE >= 4 && !SB_NO_PROBE
        // 探针：在 Siri 请求仍活跃的识别回调里直接交一条 ACE，只验证通道
        SBLogSync("PROBE in-callback submit");
        id cmd = SBAceAddViews(t);
        SBLogSync("PROBE ace=%p", (void *)cmd);
        if (cmd) SBSubmitAce(cmd, self);
        SBLogSync("PROBE returned");
#endif
        if (cs && *cs) g_textFn(t, self);
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
        if (v && strcmp(class_getName(object_getClass(v)), "AFConnection") == 0) found = v;
    }
    free(ivars);
    return found;
}

static void sbDel(id self, SEL _cmd, id recognition) {
    if (g_origDel) ((void (*)(id, SEL, id))g_origDel)(self, _cmd, recognition);
#if SB_STAGE >= 2
    id t = SBTextFrom(recognition);
    if (t && g_textFn) g_textFn(t, SBConnectionFromIvars(self));
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
