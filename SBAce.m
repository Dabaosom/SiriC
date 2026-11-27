#import "SiriBridge.h"

//  L4：字段与顺序照逆向 §5.3 / §5.4。缺 aceId/refId/displayTarget 会被拒收。
//  一律运行时构造对象，不用字面量。

id SBAceAddViewsSplit(id text, id speak);   // 1.6.13 前向声明（定义在本文件末尾上方）
id SBAceAddViewsPhase(id text, id speak, id ref, const char *phase);

id SBAceAddViews(id text) {
    return SBAceAddViewsSplit(text, text);
}

// 1.6.13：显示用 text，念用 speak。流式场景下收尾那条用全文显示、只念剩下的部分，
// 避免“首句已经念过”又被从头念一遍（实测 AddViews 会念 speakableText，TTS 是多余的）。
id SBAceAddViewsSplit(id text, id speak) { return SBAceAddViewsSplitRef(text, speak, nil); }

// 1.6.14：允许指定 refId。两条 AddViews 用同一个 refId 时，Siri 倾向原地替换而不是新开气泡。
id SBAceAddViewsSplitRef(id text, id speak, id ref) {
    return SBAceAddViewsPhase(text, speak, ref, "Completion");
}

// 1.6.15：phase 可指定。首句用 Acknowledgment，Siri 通常在终态答案到达时撤掉/替换这一档。
id SBAceAddViewsPhase(id text, id speak, id ref, const char *phase) {
    if (!text) return nil;
    if (!SBHasClassC("SAUIAddViews") || !SBHasClassC("SAUIAssistantUtteranceView")) {
        SBLogSync("ACE missing classes");
        return nil;
    }

    id view = SBNewC("SAUIAssistantUtteranceView");
    if (!view) return nil;
    if (!SBSetC(view, "setText:", text)) { SBLogSync("ACE setText fail"); SBMsgC(view, "release"); return nil; }
    if (speak) SBSetC(view, "setSpeakableText:", speak);
    else SBSetC(view, "setSpeakableText:", SBStr(""));

    id cmd = SBNewC("SAUIAddViews");
    if (!cmd) { SBMsgC(view, "release"); return nil; }
    if (!SBSetC(cmd, "setViews:", SBArr1(view))) {
        SBLogSync("ACE setViews fail"); SBMsgC(cmd, "release"); SBMsgC(view, "release"); return nil;
    }
    SBSetC(cmd, "setAceId:", SBUUIDStr());
    SBSetC(cmd, "setRefId:", ref ? ref : SBUUIDStr());
    if (!SBSetC(cmd, "setDialogPhase:", SBStr(phase ? phase : "Completion"))) {
        SBLogSync("ACE phase fail"); SBMsgC(cmd, "release"); SBMsgC(view, "release"); return nil;
    }
    if (!SBSetC(cmd, "setDisplayTarget:", SBStr("PrimaryDisplay"))) {
        SBLogSync("ACE target fail"); SBMsgC(cmd, "release"); SBMsgC(view, "release"); return nil;
    }
    SBMsgC(view, "release");
    SBLogSync("ACE addviews ok");
    return cmd;
}

id SBAcePreSynthTTS(id text) {
    if (!text) return nil;
    if (!SBHasClassC("SAPreSynthesizeTTS")) { SBLogSync("TTS missing class"); return nil; }

    id tts = SBNewC("SAPreSynthesizeTTS");
    if (!tts) return nil;
    if (!SBSetC(tts, "setDialogStrings:", SBArr1(text))) {
        SBLogSync("TTS setDialogStrings fail");
        SBMsgC(tts, "release");
        return nil;
    }
    // 键名未定性：先给空字典，不猜键
    Class dCls = objc_getClass("NSDictionary");
    id empty = ((id (*)(id, SEL))objc_msgSend)((id)dCls, sel_registerName("dictionary"));
    SBSetC(tts, "setSpeakableContextInfo:", empty);
    SBSetC(tts, "setAceId:", SBUUIDStr());
    SBSetC(tts, "setRefId:", SBUUIDStr());
    SBLogSync("TTS built ok");
    return tts;
}
