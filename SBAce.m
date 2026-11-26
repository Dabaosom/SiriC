#import "SiriBridge.h"

//  L4：字段与顺序照逆向 §5.3 / §5.4。缺 aceId/refId/displayTarget 会被拒收。
//  一律运行时构造对象，不用字面量。

id SBAceAddViews(id text) {
    if (!text) return nil;
    if (!SBHasClassC("SAUIAddViews") || !SBHasClassC("SAUIAssistantUtteranceView")) {
        SBLog("ACE missing classes");
        return nil;
    }

    id view = SBNewC("SAUIAssistantUtteranceView");
    if (!view) return nil;
    if (!SBSetC(view, "setText:", text)) { SBLog("ACE setText fail"); SBMsgC(view, "release"); return nil; }
    SBSetC(view, "setSpeakableText:", text);

    id cmd = SBNewC("SAUIAddViews");
    if (!cmd) { SBMsgC(view, "release"); return nil; }
    if (!SBSetC(cmd, "setViews:", SBArr1(view))) {
        SBLog("ACE setViews fail"); SBMsgC(cmd, "release"); SBMsgC(view, "release"); return nil;
    }
    SBSetC(cmd, "setAceId:", SBUUIDStr());
    SBSetC(cmd, "setRefId:", SBUUIDStr());
    if (!SBSetC(cmd, "setDialogPhase:", SBStr("Completion"))) {
        SBLog("ACE phase fail"); SBMsgC(cmd, "release"); SBMsgC(view, "release"); return nil;
    }
    if (!SBSetC(cmd, "setDisplayTarget:", SBStr("PrimaryDisplay"))) {
        SBLog("ACE target fail"); SBMsgC(cmd, "release"); SBMsgC(view, "release"); return nil;
    }
    SBMsgC(view, "release");
    SBLog("ACE addviews ok");
    return cmd;
}

id SBAcePreSynthTTS(id text) {
    if (!text) return nil;
    if (!SBHasClassC("SAPreSynthesizeTTS")) { SBLog("TTS missing class"); return nil; }

    id tts = SBNewC("SAPreSynthesizeTTS");
    if (!tts) return nil;
    if (!SBSetC(tts, "setDialogStrings:", SBArr1(text))) {
        SBLog("TTS setDialogStrings fail");
        SBMsgC(tts, "release");
        return nil;
    }
    // 键名未定性：先给空字典，不猜键
    Class dCls = objc_getClass("NSDictionary");
    id empty = ((id (*)(id, SEL))objc_msgSend)((id)dCls, sel_registerName("dictionary"));
    SBSetC(tts, "setSpeakableContextInfo:", empty);
    SBSetC(tts, "setAceId:", SBUUIDStr());
    SBSetC(tts, "setRefId:", SBUUIDStr());
    SBLog("TTS built ok");
    return tts;
}
