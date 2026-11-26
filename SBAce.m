#import "SiriBridge.h"

//  L4：字段与顺序照逆向 §5.3 / §5.4。缺 aceId/refId/displayTarget 会被拒收。

id SBAceAddViews(NSString *text) {
    if (!text.length) return nil;
    if (!SBHasClass(@"SAUIAddViews") || !SBHasClass(@"SAUIAssistantUtteranceView")) {
        SBLog("ACE missing classes");
        return nil;
    }

    id view = SBNew(@"SAUIAssistantUtteranceView");
    if (!view) return nil;
    if (!SBSet(view, @"setText:", text)) { SBLog("ACE setText fail"); [view release]; return nil; }
    SBSet(view, @"setSpeakableText:", text);

    id cmd = SBNew(@"SAUIAddViews");
    if (!cmd) { [view release]; return nil; }
    if (!SBSet(cmd, @"setViews:", @[ view ])) { SBLog("ACE setViews fail"); [cmd release]; [view release]; return nil; }
    SBSet(cmd, @"setAceId:", SBUUID());
    SBSet(cmd, @"setRefId:", SBUUID());
    if (!SBSet(cmd, @"setDialogPhase:", @"Completion")) { SBLog("ACE phase fail"); [cmd release]; [view release]; return nil; }
    if (!SBSet(cmd, @"setDisplayTarget:", @"PrimaryDisplay")) { SBLog("ACE target fail"); [cmd release]; [view release]; return nil; }
    [view release];
    SBLog("ACE addviews len=%lu", (unsigned long)text.length);
    return cmd;
}

id SBAcePreSynthTTS(NSString *text) {
    if (!text.length) return nil;
    if (!SBHasClass(@"SAPreSynthesizeTTS")) { SBLog("TTS missing class"); return nil; }

    id tts = SBNew(@"SAPreSynthesizeTTS");
    if (!tts) return nil;
    if (!SBSet(tts, @"setDialogStrings:", @[ text ])) {
        SBLog("TTS setDialogStrings fail");
        [tts release];
        return nil;
    }
    // 键名未定性：先给空字典，不猜键。
    SBSet(tts, @"setSpeakableContextInfo:", @{});
    SBSet(tts, @"setAceId:", SBUUID());
    SBSet(tts, @"setRefId:", SBUUID());
    SBLog("TTS built len=%lu", (unsigned long)text.length);
    return tts;
}
