#include <CoreFoundation/CoreFoundation.h>
#include <objc/runtime.h>
#include <sys/time.h>
#include <objc/message.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <stdio.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <mach/mach.h>
#include <mach/vm_map.h>

extern void sys_icache_invalidate(void *start, unsigned long len);
static void arm_aq(void);
static long long now_ms(void);

/* 注入 com.apple.siri。
   日志写自己的沙盒容器：$HOME/Library/Caches/uiprobe.log
   1) 记录 UILabel setText（只记录，不改）
   2) 从 notify a 槽接收 SpringBoard 的 AI 答案并记录（只记录，不改 UI） */

#define NB_SLOT 32

static int g_lfd = -1;
static pthread_mutex_t g_lmu = PTHREAD_MUTEX_INITIALIZER;

static void log_init(void) {
    if (g_lfd >= 0) return;
    const char *home = getenv("HOME");
    if (!home) return;
    char path[512];
    snprintf(path, sizeof path, "%s/Library/Caches/uiprobe.log", home);
    g_lfd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
}


static long long now_ms(void) {
    struct timeval tv;
    gettimeofday(&tv, 0);
    return (long long)tv.tv_sec * 1000LL + tv.tv_usec / 1000LL;
}

static void log_line(const char *s) {
    log_init();
    if (g_lfd < 0 || !s) return;
    pthread_mutex_lock(&g_lmu);
    size_t n = strlen(s);
    char b[4400];
    if (n > 4200) n = 4200;
    memcpy(b, s, n);
    b[n] = '\n';
    write(g_lfd, b, n + 1);
    pthread_mutex_unlock(&g_lmu);
}

static void chain_of(id v, char *out, int cap) {
    int n = 0;
    id cur = v;
    for (int i = 0; i < 8 && cur; i++) {
        const char *cn = class_getName(object_getClass(cur));
        n += snprintf(out + n, cap - n, "/%s", cn ? cn : "?");
        if (!((unsigned char(*)(id, SEL, SEL))objc_msgSend)(cur, sel_registerName("respondsToSelector:"),
                sel_registerName("superview"))) break;
        cur = ((id(*)(id, SEL))objc_msgSend)(cur, sel_registerName("superview"));
    }
    if (n >= cap) out[cap - 1] = 0;
}

static int g_hits = 0;

static void note_label(id lbl, const char *tag, id t) {
    if (!lbl || g_hits > 400) return;
    const char *u = 0;
    if (t && ((unsigned char(*)(id, SEL, SEL))objc_msgSend)(t, sel_registerName("respondsToSelector:"),
            sel_registerName("UTF8String")))
        u = ((const char*(*)(id, SEL))objc_msgSend)(t, sel_registerName("UTF8String"));
    g_hits++;
    char l[240];
    snprintf(l, sizeof l, "UITX %s len=%lu p=%p", tag, u ? (unsigned long)strlen(u) : 0UL, lbl);
    log_line(l);
    if (u && u[0]) {
        char pr[90];
        size_t k = strlen(u);
        if (k > 76) k = 76;
        pr[0] = '='; pr[1] = 0;
        memcpy(pr + 1, u, k);
        pr[1 + k] = 0;
        log_line(pr);
    }
    char ch[240];
    chain_of(lbl, ch, sizeof ch);
    snprintf(l, sizeof l, "UCH%s", ch);
    log_line(l);
}


/* ---- 只读枚举：找出播报文本相关入口 ---- */
static int g_disc = 0;

static void discover(id lbl) {
    if (g_disc) return;
    g_disc = 1;
    log_line("UDISC begin");
    id cur = lbl;
    for (int i = 0; i < 5 && cur; i++) {
        const char *cn = class_getName(object_getClass(cur));
        char l[200];
        snprintf(l, sizeof l, "UDISC up%d %s", i, cn ? cn : "?");
        log_line(l);
        unsigned int cnt = 0;
        Method *ms = class_copyMethodList(object_getClass(cur), &cnt);
        int shown = 0;
        for (unsigned k = 0; k < cnt && shown < 14; k++) {
            const char *sn = sel_getName(method_getName(ms[k]));
            if (!sn) continue;
            if (!strstr(sn, "speak") && !strstr(sn, "Speak") && !strstr(sn, "utterance")
                && !strstr(sn, "Utterance") && !strstr(sn, "text") && !strstr(sn, "Text"))
                continue;
            char l2[200];
            snprintf(l2, sizeof l2, "UDISC  m %s", sn);
            log_line(l2);
            shown++;
        }
        if (ms) free(ms);
        if (!((unsigned char(*)(id, SEL, SEL))objc_msgSend)(cur, sel_registerName("respondsToSelector:"),
                sel_registerName("superview"))) break;
        cur = ((id(*)(id, SEL))objc_msgSend)(cur, sel_registerName("superview"));
    }
    int ncls = objc_getClassList(NULL, 0);
    if (ncls > 0) {
        Class *all = (Class *)malloc(sizeof(Class) * (size_t)ncls);
        if (all) {
            int got = objc_getClassList(all, ncls);
            int shown = 0;
            for (int i = 0; i < got && shown < 30; i++) {
                const char *nm = class_getName(all[i]);
                if (!nm) continue;
                if (!strstr(nm, "Utterance") && !strstr(nm, "SiriTTS") && !strstr(nm, "Speakable")
                    && !strstr(nm, "CompactServer")) continue;
                char l3[200];
                snprintf(l3, sizeof l3, "UDISC cls %s", nm);
                log_line(l3);
                shown++;
            }
            free(all);
        }
    }
    log_line("UDISC end");
}

static IMP o_setText = 0;
static IMP o_setAttr = 0;

static void my_setText(id self, SEL _cmd, id t) {
    note_label(self, "setText", t);
    const char *cn = self ? class_getName(object_getClass(self)) : "";
    if (cn && strstr(cn, "ServerUtteranceLabel") && t) {
        discover(self);
        id mk = ((id(*)(id, SEL, const char *))objc_msgSend)((id)objc_getClass("NSString"),
                 sel_registerName("stringWithUTF8String:"), "AI测试文本XYZ 一二三四五");
        if (mk) {
            if (o_setText) ((void(*)(id, SEL, id))o_setText)(self, _cmd, mk);
            id rb = ((id(*)(id, SEL))objc_msgSend)(self, sel_registerName("text"));
            const char *u = rb ? ((const char*(*)(id, SEL))objc_msgSend)(rb, sel_registerName("UTF8String")) : 0;
            char l[160];
            snprintf(l, sizeof l, "UINV replace readback=%s", u ? u : "nil");
            log_line(l);
            {
                static const char *sels[] = {"speakableText", "speechText", "utterance", "viewModel",
                                             "assistantUtteranceView", "siriUtterance", "spokenText"};
                for (unsigned si = 0; si < sizeof sels / sizeof sels[0]; si++) {
                    char lx[200];
                    unsigned char rs = ((unsigned char(*)(id, SEL, SEL))objc_msgSend)(self,
                        sel_registerName("respondsToSelector:"), sel_registerName(sels[si]));
                    if (!rs) { snprintf(lx, sizeof lx, "UISEL %s=no", sels[si]); log_line(lx); continue; }
                    id v = ((id(*)(id, SEL))objc_msgSend)(self, sel_registerName(sels[si]));
                    snprintf(lx, sizeof lx, "UISEL %s=yes v=%s", sels[si], v ? class_getName(object_getClass(v)) : "nil");
                    log_line(lx);
                }
                unsigned int ic = 0;
                Ivar *iv = class_copyIvarList(object_getClass(self), &ic);
                int shown = 0;
                for (unsigned k = 0; k < ic && shown < 24; k++) {
                    const char *in = ivar_getName(iv[k]);
                    if (!in) continue;
                    if (!strstr(in, "peak") && !strstr(in, "odel") && !strstr(in, "tterance")
                        && !strstr(in, "Text") && !strstr(in, "text")) continue;
                    char ly[200];
                    snprintf(ly, sizeof ly, "UIVAR %s", in);
                    log_line(ly);
                    shown++;
                }
                if (iv) free(iv);
            }
            /* 只读：看这条 utterance view 的可播报字段 */
            if (((unsigned char(*)(id, SEL, SEL))objc_msgSend)(self, sel_registerName("respondsToSelector:"),
                    sel_registerName("assistantUtteranceView"))) {
                id auv = ((id(*)(id, SEL))objc_msgSend)(self, sel_registerName("assistantUtteranceView"));
                if (auv) {
                    char l4[200];
                    snprintf(l4, sizeof l4, "UINV auv %s", class_getName(object_getClass(auv)));
                    log_line(l4);
                    unsigned int cnt = 0;
                    Method *ms = class_copyMethodList(object_getClass(auv), &cnt);
                    int shown = 0;
                    for (unsigned k = 0; k < cnt && shown < 20; k++) {
                        const char *sn = sel_getName(method_getName(ms[k]));
                        if (!sn) continue;
                        if (!strstr(sn, "peak") && !strstr(sn, "Text") && !strstr(sn, "text")) continue;
                        char l5[200];
                        snprintf(l5, sizeof l5, "UINV m %s", sn);
                        log_line(l5);
                        shown++;
                    }
                    if (ms) free(ms);
                    if (((unsigned char(*)(id, SEL, SEL))objc_msgSend)(auv, sel_registerName("respondsToSelector:"),
                            sel_registerName("speakableText"))) {
                        id st = ((id(*)(id, SEL))objc_msgSend)(auv, sel_registerName("speakableText"));
                        const char *sv = st ? ((const char*(*)(id, SEL))objc_msgSend)(st, sel_registerName("UTF8String")) : 0;
                        char l6[220];
                        snprintf(l6, sizeof l6, "UINV speakable=%s", sv ? sv : "nil");
                        log_line(l6);
                    } else {
                        log_line("UINV no speakableText");
                    }
                }
            }
            return;
        }
    }
    if (o_setText) ((void(*)(id, SEL, id))o_setText)(self, _cmd, t);
}

static void my_setAttr(id self, SEL _cmd, id t) {
    note_label(self, "setAttr", t);
    if (o_setAttr) ((void(*)(id, SEL, id))o_setAttr)(self, _cmd, t);
}


static IMP o_setAUV = 0;

static void my_setAUV(id self, SEL _cmd, id v) {
    const char *cn = v ? class_getName(object_getClass(v)) : "nil";
    arm_aq();
    char l[220];
    snprintf(l, sizeof l, "UAUV t=%lld class=%s", now_ms() % 100000, cn);
    log_line(l);
    if (v) {
        static const char *sels[] = {"speakableText", "text", "speechText", "utteranceText",
                                     "assistantUtteranceView", "dialogIdentifier", "viewId"};
        for (unsigned si = 0; si < sizeof sels / sizeof sels[0]; si++) {
            unsigned char rs = ((unsigned char(*)(id, SEL, SEL))objc_msgSend)(v,
                sel_registerName("respondsToSelector:"), sel_registerName(sels[si]));
            if (!rs) continue;
            id x = ((id(*)(id, SEL))objc_msgSend)(v, sel_registerName(sels[si]));
            char l2[220];
            if (x && ((unsigned char(*)(id, SEL, SEL))objc_msgSend)(x, sel_registerName("respondsToSelector:"),
                    sel_registerName("UTF8String"))) {
                const char *u = ((const char*(*)(id, SEL))objc_msgSend)(x, sel_registerName("UTF8String"));
                snprintf(l2, sizeof l2, "UAUV %s=%.90s", sels[si], u ? u : "");
            } else {
                snprintf(l2, sizeof l2, "UAUV %s cls=%s", sels[si],
                         x ? class_getName(object_getClass(x)) : "nil");
            }
            log_line(l2);
        }
        unsigned int ic = 0;
        Ivar *iv = class_copyIvarList(object_getClass(v), &ic);
        int shown = 0;
        for (unsigned k = 0; k < ic && shown < 20; k++) {
            const char *in = ivar_getName(iv[k]);
            if (!in) continue;
            if (!strstr(in, "peak") && !strstr(in, "odel") && !strstr(in, "Text") && !strstr(in, "text")) continue;
            char l3[200];
            snprintf(l3, sizeof l3, "UAUV ivar %s", in);
            log_line(l3);
            shown++;
        }
        if (iv) free(iv);
    }
    if (v && ((unsigned char(*)(id, SEL, SEL))objc_msgSend)(v, sel_registerName("respondsToSelector:"),
            sel_registerName("setSpeakableText:"))) {
        id mk = ((id(*)(id, SEL, const char *))objc_msgSend)((id)objc_getClass("NSString"),
                 sel_registerName("stringWithUTF8String:"), "AI语音测试 一二三四五六七");
        ((void(*)(id, SEL, id))objc_msgSend)(v, sel_registerName("setSpeakableText:"), mk);
        id rb = ((id(*)(id, SEL))objc_msgSend)(v, sel_registerName("speakableText"));
        const char *u = rb ? ((const char*(*)(id, SEL))objc_msgSend)(rb, sel_registerName("UTF8String")) : 0;
        char ls[220];
        snprintf(ls, sizeof ls, "USPK t=%lld readback=%s", now_ms() % 100000, u ? u : "nil");
        log_line(ls);
    } else {
        log_line("USPK no setSpeakableText");
    }
    if (o_setAUV) ((void(*)(id, SEL, id))o_setAUV)(self, _cmd, v);
}


/* ---- 只读：看原生播报由谁放出来 ---- */
static IMP o_avp_play = 0, o_avq_play = 0, o_eng_start = 0;

static void my_avp_play(id self, SEL _cmd) {
    double dur = 0, vol = 0;
    if (((unsigned char(*)(id, SEL, SEL))objc_msgSend)(self, sel_registerName("respondsToSelector:"),
            sel_registerName("duration")))
        dur = ((double(*)(id, SEL))objc_msgSend)(self, sel_registerName("duration"));
    if (((unsigned char(*)(id, SEL, SEL))objc_msgSend)(self, sel_registerName("respondsToSelector:"),
            sel_registerName("volume")))
        vol = ((double(*)(id, SEL))objc_msgSend)(self, sel_registerName("volume"));
    char l[180];
    snprintf(l, sizeof l, "UPLAY t=%lld %s dur=%.2f vol=%.2f", now_ms() % 100000,
             class_getName(object_getClass(self)), dur, vol);
    log_line(l);
    if (o_avp_play) ((void(*)(id, SEL))o_avp_play)(self, _cmd);
}

static void my_avq_play(id self, SEL _cmd) {
    char l[160];
    snprintf(l, sizeof l, "UPLAY t=%lld %s", now_ms() % 100000, class_getName(object_getClass(self)));
    log_line(l);
    if (o_avq_play) ((void(*)(id, SEL))o_avq_play)(self, _cmd);
}

static void my_eng_start(id self, SEL _cmd) {
    char l[160];
    snprintf(l, sizeof l, "UPLAY t=%lld %s engine", now_ms() % 100000, class_getName(object_getClass(self)));
    log_line(l);
    if (o_eng_start) ((void(*)(id, SEL))o_eng_start)(self, _cmd);
}

static void hook_player(Class c, const char *sel, IMP fn, IMP *orig) {
    if (!c) return;
    Method m = class_getInstanceMethod(c, sel_registerName(sel));
    if (m) *orig = method_setImplementation(m, fn);
}

static void enum_tts(void) {
    const char *names[] = {"SiriTTSService.AVSBARPlayback", "SiriTTSService.AudioPlaybackAction",
                           "SiriTTSService.DelegateHandler", "SiriTTSService.AudioFile"};
    for (unsigned i = 0; i < sizeof names / sizeof names[0]; i++) {
        Class c = objc_getClass(names[i]);
        if (!c) { char l[200]; snprintf(l, sizeof l, "UTTS no %s", names[i]); log_line(l); continue; }
        char l0[200];
        snprintf(l0, sizeof l0, "UTTS cls %s", names[i]);
        log_line(l0);
        unsigned int cnt = 0;
        Method *ms = class_copyMethodList(c, &cnt);
        int shown = 0;
        for (unsigned k = 0; k < cnt && shown < 16; k++) {
            const char *sn = sel_getName(method_getName(ms[k]));
            if (!sn) continue;
            if (!strstr(sn, "play") && !strstr(sn, "Play") && !strstr(sn, "start") && !strstr(sn, "stop")
                && !strstr(sn, "synth") && !strstr(sn, "speak") && !strstr(sn, "audio")) continue;
            char l2[240];
            snprintf(l2, sizeof l2, "UTTS  %s m %s", names[i], sn);
            log_line(l2);
            shown++;
        }
        if (ms) free(ms);
    }
}


/* ---- 只读：音频通路 ---- */
static IMP o_as_cat = 0, o_as_act = 0;

static void my_as_cat(id self, SEL _cmd, id cat) {
    const char *u = cat ? ((const char*(*)(id, SEL))objc_msgSend)(cat, sel_registerName("UTF8String")) : "nil";
    char l[200];
    snprintf(l, sizeof l, "UAS t=%lld setCategory=%.60s", now_ms() % 100000, u ? u : "nil");
    log_line(l);
    if (o_as_cat) ((void(*)(id, SEL, id))o_as_cat)(self, _cmd, cat);
}

static void my_as_act(id self, SEL _cmd, unsigned char on, unsigned long opts, id *err) {
    char l[160];
    snprintf(l, sizeof l, "UAS t=%lld setActive=%d", now_ms() % 100000, on ? 1 : 0);
    log_line(l);
    if (o_as_act) ((void(*)(id, SEL, unsigned char, unsigned long, id *))o_as_act)(self, _cmd, on, opts, err);
}

static void enum_audio_classes(void) {
    int ncls = objc_getClassList(NULL, 0);
    if (ncls <= 0) return;
    Class *all = (Class *)malloc(sizeof(Class) * (size_t)ncls);
    if (!all) return;
    int got = objc_getClassList(all, ncls);
    int shown = 0;
    for (int i = 0; i < got && shown < 40; i++) {
        const char *nm = class_getName(all[i]);
        if (!nm) continue;
        if (!strstr(nm, "Audio") && !strstr(nm, "Osprey") && !strstr(nm, "Speech")) continue;
        if (strstr(nm, "AU") || strstr(nm, "AudioToolbox")) continue;
        char l[200];
        snprintf(l, sizeof l, "UACLS %s", nm);
        log_line(l);
        shown++;
    }
    free(all);
}


/* ---- 只读：AVSampleBufferAudioRenderer 通路 ---- */
static IMP o_enq = 0;
static int g_enq = 0;

static void my_enq(id self, SEL _cmd, void *sbuf) {
    g_enq++;
    if (g_enq <= 12) {
        char l[200];
        snprintf(l, sizeof l, "USB t=%lld enq=%d cls=%s", now_ms() % 100000, g_enq,
                 class_getName(object_getClass(self)));
        log_line(l);
    }
    if (o_enq) ((void(*)(id, SEL, void *))o_enq)(self, _cmd, sbuf);
}


/* ---- 只读：Siri App 里可用的会话 / 播报 / 取消 入口 ---- */
static void enum_sess(void) {
    const char *key[] = {"SiriUISession", "AFUISiri", "SRUIF", "SiriSession", "Speech", "SiriTTS"};
    const char *kw[] = {"speech", "Speech", "tts", "TTS", "cancel", "Cancel", "stop", "Stop", "utterance", "Utterance"};
    int ncls = objc_getClassList(NULL, 0);
    if (ncls <= 0) return;
    Class *all = (Class *)malloc(sizeof(Class) * (size_t)ncls);
    if (!all) return;
    int got = objc_getClassList(all, ncls);
    int shown = 0;
    for (int i = 0; i < got && shown < 70; i++) {
        const char *nm = class_getName(all[i]);
        if (!nm) continue;
        int hit = 0;
        for (unsigned k = 0; k < sizeof key / sizeof key[0]; k++) if (strstr(nm, key[k])) { hit = 1; break; }
        if (!hit) continue;
        char l[220];
        snprintf(l, sizeof l, "USESS cls %s", nm);
        log_line(l);
        shown++;
        unsigned int cnt = 0;
        Method *ms = class_copyMethodList(all[i], &cnt);
        int m2 = 0;
        for (unsigned k = 0; k < cnt && m2 < 6; k++) {
            const char *sn = sel_getName(method_getName(ms[k]));
            if (!sn) continue;
            int hit2 = 0;
            for (unsigned j = 0; j < sizeof kw / sizeof kw[0]; j++) if (strstr(sn, kw[j])) { hit2 = 1; break; }
            if (!hit2) continue;
            char l3[240];
            snprintf(l3, sizeof l3, "USESS  %s m %s", nm, sn);
            log_line(l3);
            m2++;
            shown++;
        }
        if (ms) free(ms);
    }
    free(all);
}


/* ---- 只读：Siri App 内 AFConnection 的命令到达时机 ---- */
static IMP o_ac_h1 = 0, o_ac_h2 = 0, o_ac_h3 = 0;

static void note_cmd(const char *tag, id cmd) {
    if (!cmd) { char l[120]; snprintf(l, sizeof l, "UAC %s nil", tag); log_line(l); return; }
    const char *cn = class_getName(object_getClass(cmd));
    char l[200];
    snprintf(l, sizeof l, "UAC t=%lld %s cmd=%s", now_ms() % 100000, tag, cn ? cn : "?");
    log_line(l);
    if (!((unsigned char(*)(id, SEL, SEL))objc_msgSend)(cmd, sel_registerName("respondsToSelector:"),
            sel_registerName("views"))) return;
    id views = ((id(*)(id, SEL))objc_msgSend)(cmd, sel_registerName("views"));
    if (!views) { log_line("UAC  views nil"); return; }
    unsigned long n = ((unsigned long(*)(id, SEL))objc_msgSend)(views, sel_registerName("count"));
    char l2[140];
    snprintf(l2, sizeof l2, "UAC  views n=%lu", n);
    log_line(l2);
    for (unsigned long i = 0; i < n && i < 4; i++) {
        id v = ((id(*)(id, SEL, unsigned long))objc_msgSend)(views, sel_registerName("objectAtIndex:"), i);
        char l3[200];
        snprintf(l3, sizeof l3, "UAC  v%lu %s", i, v ? class_getName(object_getClass(v)) : "nil");
        log_line(l3);
        if (v && ((unsigned char(*)(id, SEL, SEL))objc_msgSend)(v, sel_registerName("respondsToSelector:"),
                sel_registerName("speakableText"))) {
            id st = ((id(*)(id, SEL))objc_msgSend)(v, sel_registerName("speakableText"));
            const char *u = st ? ((const char*(*)(id, SEL))objc_msgSend)(st, sel_registerName("UTF8String")) : 0;
            char l4[240];
            snprintf(l4, sizeof l4, "UAC  v%lu speak=%.80s", i, u ? u : "nil");
            log_line(l4);
        }
    }
}

static void my_ac_h1(id self, SEL _cmd, id cmd, id reply) {
    note_cmd("h1", cmd);
    if (o_ac_h1) ((void(*)(id, SEL, id, id))o_ac_h1)(self, _cmd, cmd, reply);
}

static void my_ac_h2(id self, SEL _cmd, id cmd, id reply) {
    note_cmd("h2", cmd);
    if (o_ac_h2) ((void(*)(id, SEL, id, id))o_ac_h2)(self, _cmd, cmd, reply);
}

static void my_ac_h3(id self, SEL _cmd, id cmd, id reply) {
    note_cmd("h3", cmd);
    if (o_ac_h3) ((void(*)(id, SEL, id, id))o_ac_h3)(self, _cmd, cmd, reply);
}


/* ---- 只读：AudioQueue C 接口调用时机（inline hook，不改行为） ---- */
typedef int (*AQStartFn)(void *, const void *);
typedef int (*AQEnqFn)(void *, void *, unsigned, const void *);
static AQStartFn o_aqstart = 0;
static AQEnqFn o_aqenq = 0;
static int g_aq_on = 0;

static void *hook_c(void *target, void *repl, void **orig);
static void arm_aq(void);

static int my_aqstart(void *aq, const void *ts) {
    char l[160];
    snprintf(l, sizeof l, "UAQ t=%lld start aq=%p", now_ms() % 100000, aq);
    log_line(l);
    if (!o_aqstart) return 0;
    return o_aqstart(aq, ts);
}

static int my_aqenq(void *aq, void *buf, unsigned n, const void *pkts) {
    char l[160];
    snprintf(l, sizeof l, "UAQ t=%lld enq aq=%p n=%u", now_ms() % 100000, aq, n);
    log_line(l);
    if (!o_aqenq) return 0;
    return o_aqenq(aq, buf, n, pkts);
}

/* 16 字节补丁：ldr x16,#8 ; br x16 ; .quad dest */
static void *new_page(void) {
    unsigned char *p = (unsigned char *)mmap(0, 4096, PROT_READ | PROT_WRITE,
                          MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (!p || p == (unsigned char *)-1) return 0;
    return p;
}

static void *hook_c(void *target, void *repl, void **orig) {
    if (!target) return 0;
    target = (void *)((unsigned long)target & 0x00007FFFFFFFFFFFUL);
    unsigned char *tramp = (unsigned char *)new_page();
    unsigned char *island = (unsigned char *)new_page();
    if (!tramp || !island) return 0;
    /* trampoline: 前 16 字节保留原指令，随后跳回 target+16 */
    memcpy(tramp, target, 16);
    *(unsigned long *)(tramp + 16) = 0x58000050UL;
    *(unsigned long *)(tramp + 20) = 0xD61F0200UL;
    *(unsigned long *)(tramp + 24) = (unsigned long)((char *)target + 16) & 0x00007FFFFFFFFFFFUL;
    /* island: 跳到 repl */
    *(unsigned long *)(island + 0) = 0x58000050UL;
    *(unsigned long *)(island + 4) = 0xD61F0200UL;
    *(unsigned long *)(island + 8) = (unsigned long)repl & 0x00007FFFFFFFFFFFUL;
    mprotect(tramp, 4096, PROT_READ | PROT_EXEC);
    mprotect(island, 4096, PROT_READ | PROT_EXEC);
    sys_icache_invalidate(tramp, 4096);
    sys_icache_invalidate(island, 4096);
    /* 覆盖目标函数头 */
    unsigned long pg = (unsigned long)target & ~0xFFFUL;
    kern_return_t kr = vm_protect(mach_task_self(), (vm_address_t)pg, 8192, 0,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    char kmsg[160];
    snprintf(kmsg, sizeof kmsg, "UAQ vm_protect kr=%d", (int)kr);
    log_line(kmsg);
    if (kr != KERN_SUCCESS) return 0;
    memcpy(target, island, 16);
    vm_protect(mach_task_self(), (vm_address_t)pg, 8192, 0, VM_PROT_READ | VM_PROT_EXECUTE);
    sys_icache_invalidate((void *)pg, 8192);
    if (orig) *orig = (void *)tramp;
    return tramp;
}

static void arm_aq(void) {
    if (g_aq_on) return;
    g_aq_on = 1;
    void *h = dlopen("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox", RTLD_NOW);
    if (!h) { log_line("UAQ no AudioToolbox"); return; }
    void *f1 = dlsym(h, "AudioQueueStart");
    void *f2 = dlsym(h, "AudioQueueEnqueueBuffer");
    char l[160];
    snprintf(l, sizeof l, "UAQ dlsym start=%p enq=%p", f1, f2);
    log_line(l);
    hook_c(f1, (void *)my_aqstart, (void **)&o_aqstart);
    hook_c(f2, (void *)my_aqenq, (void **)&o_aqenq);
    snprintf(l, sizeof l, "UAQ hooked start=%d enq=%d", o_aqstart ? 1 : 0, o_aqenq ? 1 : 0);
    {
        void *hx = dlopen("/usr/lib/libxpc.dylib", RTLD_NOW);
        void *fx = hx ? dlsym(hx, "xpc_connection_send_message") : 0;
        char lx[120];
        snprintf(lx, sizeof lx, "UXPC sym=%p", fx);
        log_line(lx);
        if (fx) {
            hook_c(fx, (void *)my_xsend, (void **)&o_xsend);
            log_line("UXPC hooked");
        }
    }
    log_line(l);
}


/* ---- 只读：Siri App 的 XPC 发送内容 ---- */
typedef void (*XpcSendFn)(void *, void *);
static XpcSendFn o_xsend = 0;
static int g_xsend = 0;

static void my_xsend(void *conn, void *msg) {
    g_xsend++;
    if (g_xsend <= 15 && msg) {
        char *desc = xpc_copy_description(msg);
        if (desc) {
            size_t n = strlen(desc);
            char buf[260];
            size_t k = n > 220 ? 220 : n;
            snprintf(buf, sizeof buf, "UXPC n=%d %.220s", g_xsend, desc);
            /* 去掉换行，日志按行读 */
            for (char *ch = buf; *ch; ch++) if (*ch == '\n' || *ch == '\r') *ch = ' ';
            log_line(buf);
            free(desc);
        } else {
            char l[80];
            snprintf(l, sizeof l, "UXPC n=%d nodesc", g_xsend);
            log_line(l);
        }
    }
    if (o_xsend) o_xsend(conn, msg);
}

static void install_hooks(void) {
    Class lc = objc_getClass("UILabel");
    if (!lc) { log_line("UIPROBE no UILabel"); return; }
    Method m = class_getInstanceMethod(lc, sel_registerName("setText:"));
    if (m) o_setText = method_setImplementation(m, (IMP)my_setText);
    Method m2 = class_getInstanceMethod(lc, sel_registerName("setAttributedText:"));
    if (m2) o_setAttr = method_setImplementation(m2, (IMP)my_setAttr);
    Class sc = objc_getClass("SiriSharedUICompactServerUtteranceLabel");
    if (sc) {
        Method ma = class_getInstanceMethod(sc, sel_registerName("setAssistantUtteranceView:"));
        if (ma) {
            o_setAUV = method_setImplementation(ma, (IMP)my_setAUV);
            log_line("UIPROBE hooks setAUV ok");
        } else {
            log_line("UIPROBE no setAUV method");
        }
    } else {
        log_line("UIPROBE no ServerUtteranceLabel class");
    }
    hook_player(objc_getClass("AVAudioPlayer"), "play", (IMP)my_avp_play, &o_avp_play);
    hook_player(objc_getClass("AVQueuePlayer"), "play", (IMP)my_avq_play, &o_avq_play);
    hook_player(objc_getClass("AVPlayer"), "play", (IMP)my_avq_play, &o_avq_play);
    hook_player(objc_getClass("AVAudioEngine"), "startAndReturnError:", (IMP)my_eng_start, &o_eng_start);
    enum_tts();
    enum_audio_classes();
    {
        Class ac = objc_getClass("AVAudioSession");
        if (ac) {
            Method m1 = class_getInstanceMethod(ac, sel_registerName("setCategory:error:"));
            Method m2 = class_getInstanceMethod(ac, sel_registerName("setCategory:withOptions:error:"));
            Method m3 = class_getInstanceMethod(ac, sel_registerName("setActive:withOptions:error:"));
            if (m1) { o_as_cat = method_setImplementation(m1, (IMP)my_as_cat); log_line("UAS hook setCategory:error:"); }
            if (m2) { o_as_cat = method_setImplementation(m2, (IMP)my_as_cat); log_line("UAS hook setCategory:withOptions:error:"); }
            if (m3) { o_as_act = method_setImplementation(m3, (IMP)my_as_act); log_line("UAS hook setActive:withOptions:error:"); }
        } else {
            log_line("UAS no AVAudioSession");
        }
    }
    {
        Class r = objc_getClass("AVSampleBufferAudioRenderer");
        if (r) {
            Method m = class_getInstanceMethod(r, sel_registerName("enqueueSampleBuffer:"));
            if (m) {
                o_enq = method_setImplementation(m, (IMP)my_enq);
                log_line("USB hook enqueueSampleBuffer ok");
            } else {
                log_line("USB no enqueueSampleBuffer");
            }
        } else {
            log_line("USB no AVSampleBufferAudioRenderer");
        }
        Class rs = objc_getClass("AVSampleBufferRenderSynchronizer");
        if (rs) log_line("USB sync cls yes");
    }
    log_line("UIPROBE hooks UILabel ok");
    enum_sess();
    {
        Class ac = objc_getClass("AFConnection");
        if (ac) {
            Method m1 = class_getInstanceMethod(ac, sel_registerName("_handleCommand:reply:"));
            Method m2 = class_getInstanceMethod(ac, sel_registerName("requestHandleCommand:reply:"));
            Method m3 = class_getInstanceMethod(ac, sel_registerName("requestDidReceiveCommand:reply:"));
            if (m1) { o_ac_h1 = method_setImplementation(m1, (IMP)my_ac_h1); log_line("UAC hook _handleCommand ok"); }
            if (m2) { o_ac_h2 = method_setImplementation(m2, (IMP)my_ac_h2); log_line("UAC hook requestHandleCommand ok"); }
            if (m3) { o_ac_h3 = method_setImplementation(m3, (IMP)my_ac_h3); log_line("UAC hook requestDidReceiveCommand ok"); }
            if (!m1 && !m2 && !m3) log_line("UAC no cmd methods");
        } else {
            log_line("UAC no AFConnection");
        }
    }
    log_line("USESS done");
}

/* ---- 从 a 槽接收答案 ---- */
static int (*nf_reg)(const char *, int *) = 0;
static int (*nf_get)(int, unsigned long long *) = 0;
static int g_atok[NB_SLOT];
static int g_afl = -1;
static unsigned long long g_last_seq = 0;

static long long cpval(int idx) {
    unsigned long long v = 0;
    if (idx < 0 || !nf_get) return -1;
    if (nf_get(idx, &v) == 0) return (long long)(v % 2097152ULL);
    return -1;
}

static void *ans_thread(void *a) {
    (void)a;
    sleep(3);
    nf_reg = dlsym(RTLD_DEFAULT, "notify_register_check");
    nf_get = dlsym(RTLD_DEFAULT, "notify_get_state");
    if (!nf_reg || !nf_get) { log_line("UANS nodlsym"); return 0; }
    char nm[48];
    for (int i = 0; i < NB_SLOT; i++) {
        g_atok[i] = -1;
        snprintf(nm, sizeof nm, "com.doubao.a%d", i);
        nf_reg(nm, &g_atok[i]);
    }
    nf_reg("com.doubao.aflush", &g_afl);
    {
        char l[120];
        snprintf(l, sizeof l, "UANS tok a0=%d fl=%d", g_atok[0], g_afl);
        log_line(l);
    }
    log_line("UANS listen");

    char buf[4200];
    int bn = 0;
    int idle = 0;
    int logged = 0;
    for (;;) {
        usleep(150000);
        unsigned long long fl = 0;
        if (g_afl < 0 || nf_get(g_afl, &fl) != 0) continue;
        if (fl != g_last_seq && logged < 40) {
            char l[100];
            snprintf(l, sizeof l, "UANS fl=%llu last=%llu", fl, g_last_seq);
            log_line(l);
            logged++;
        }
        if (fl == 0 || fl == g_last_seq) { idle++; continue; }
        if (fl > g_last_seq) {
            g_last_seq = fl;
            idle = 0;
            {
                long long c0 = cpval(g_atok[0]);
                long long c1 = cpval(g_atok[1]);
                char l[140];
                snprintf(l, sizeof l, "UANS dbg fl=%llu cp0=%lld cp1=%lld bn=%d", fl, c0, c1, bn);
                log_line(l);
            }
            for (int i = 0; i < NB_SLOT; i++) {
                long long cp = cpval(g_atok[i]);
                if (cp <= 0) continue;
                if (bn > 4000) break;
                if (cp < 0x80) buf[bn++] = (char)cp;
                else if (cp < 0x800) { buf[bn++] = (char)(0xC0 | (cp >> 6)); buf[bn++] = (char)(0x80 | (cp & 0x3F)); }
                else if (cp < 0x10000) { buf[bn++] = (char)(0xE0 | (cp >> 12)); buf[bn++] = (char)(0x80 | ((cp >> 6) & 0x3F)); buf[bn++] = (char)(0x80 | (cp & 0x3F)); }
                else { buf[bn++] = (char)(0xF0 | (cp >> 18)); buf[bn++] = (char)(0x80 | ((cp >> 12) & 0x3F)); buf[bn++] = (char)(0x80 | ((cp >> 6) & 0x3F)); buf[bn++] = (char)(0x80 | (cp & 0x3F)); }
            }
        }
        if (idle == 4) {
            char l2[90];
            snprintf(l2, sizeof l2, "UANS idle bn=%d", bn);
            log_line(l2);
        }
        if (idle >= 4 && bn > 0) {
            char l[80];
            snprintf(l, sizeof l, "UANS got len=%d", bn);
            log_line(l);
            log_line(buf);
            bn = 0;
        }
    }
    return 0;
}


/* ---- 网络自测：在 com.apple.siri 内用同步请求发一次 HTTPS（已验证可靠的路径） ---- */
static void net_test(void) {
    log_line("UNET begin");
    id req = ((id(*)(id, SEL))objc_msgSend)(
              ((id(*)(id, SEL))objc_msgSend)((id)objc_getClass("NSMutableURLRequest"), sel_registerName("alloc")),
              sel_registerName("init"));
    if (!req) { log_line("UNET no req"); return; }
    id url = ((id(*)(id, SEL, id))objc_msgSend)((id)objc_getClass("NSURL"),
              sel_registerName("URLWithString:"),
              ((id(*)(id, SEL, const char *))objc_msgSend)((id)objc_getClass("NSString"),
                  sel_registerName("stringWithUTF8String:"), "https://apihub.agnes-ai.com/v1/chat/completions"));
    ((void(*)(id, SEL, id))objc_msgSend)(req, sel_registerName("setURL:"), url);
    ((void(*)(id, SEL, id))objc_msgSend)(req, sel_registerName("setHTTPMethod:"),
        ((id(*)(id, SEL, const char *))objc_msgSend)((id)objc_getClass("NSString"),
            sel_registerName("stringWithUTF8String:"), "POST"));
    id ct = ((id(*)(id, SEL, const char *))objc_msgSend)((id)objc_getClass("NSString"),
        sel_registerName("stringWithUTF8String:"), "application/json");
    ((void(*)(id, SEL, id, id))objc_msgSend)(req, sel_registerName("setValue:forHTTPHeaderField:"),
        ct, ((id(*)(id, SEL, const char *))objc_msgSend)((id)objc_getClass("NSString"),
            sel_registerName("stringWithUTF8String:"), "Content-Type"));
    id auth = ((id(*)(id, SEL, const char *))objc_msgSend)((id)objc_getClass("NSString"),
        sel_registerName("stringWithUTF8String:"),
        "Bearer sk-V0QgHosRfr9EIMgHG6SdQX60z5zVq3JXG0zJ4uNfsPxdsmis");
    ((void(*)(id, SEL, id, id))objc_msgSend)(req, sel_registerName("setValue:forHTTPHeaderField:"),
        auth, ((id(*)(id, SEL, const char *))objc_msgSend)((id)objc_getClass("NSString"),
            sel_registerName("stringWithUTF8String:"), "Authorization"));
    id body = ((id(*)(id, SEL, const char *))objc_msgSend)((id)objc_getClass("NSString"),
        sel_registerName("stringWithUTF8String:"),
        "{\"model\":\"agnes-3.0-flash\",\"messages\":[{\"role\":\"user\",\"content\":\"讲个笑话\"}]}");
    id bdata = ((id(*)(id, SEL, unsigned long))objc_msgSend)(body,
        sel_registerName("dataUsingEncoding:"), 4UL);
    ((void(*)(id, SEL, id))objc_msgSend)(req, sel_registerName("setHTTPBody:"), bdata);

    id resp = 0, err = 0;
    id data = ((id(*)(id, SEL, id, id *, id *))objc_msgSend)((id)objc_getClass("NSURLConnection"),
        sel_registerName("sendSynchronousRequest:returningResponse:error:"), req, &resp, &err);
    char l[140];
    long dl = data ? (long)((unsigned long(*)(id, SEL))objc_msgSend)(data, sel_registerName("length")) : -1;
    long code = 0;
    if (resp) code = (long)((long(*)(id, SEL))objc_msgSend)(resp, sel_registerName("statusCode"));
    snprintf(l, sizeof l, "UNET done code=%ld len=%ld err=%d", code, dl, err ? 1 : 0);
    log_line(l);
    if (!data) return;
    id js = ((id(*)(id, SEL, id, unsigned long, id *))objc_msgSend)((id)objc_getClass("NSJSONSerialization"),
        sel_registerName("JSONObjectWithData:options:error:"), data, 0UL, (id *)0);
    id choices = js ? ((id(*)(id, SEL, id))objc_msgSend)(js, sel_registerName("objectForKey:"),
        ((id(*)(id, SEL, const char *))objc_msgSend)((id)objc_getClass("NSString"),
            sel_registerName("stringWithUTF8String:"), "choices")) : 0;
    id first = choices ? ((id(*)(id, SEL, unsigned long))objc_msgSend)(choices, sel_registerName("objectAtIndex:"), 0UL) : 0;
    id msg = first ? ((id(*)(id, SEL, id))objc_msgSend)(first, sel_registerName("objectForKey:"),
        ((id(*)(id, SEL, const char *))objc_msgSend)((id)objc_getClass("NSString"),
            sel_registerName("stringWithUTF8String:"), "message")) : 0;
    id content = msg ? ((id(*)(id, SEL, id))objc_msgSend)(msg, sel_registerName("objectForKey:"),
        ((id(*)(id, SEL, const char *))objc_msgSend)((id)objc_getClass("NSString"),
            sel_registerName("stringWithUTF8String:"), "content")) : 0;
    const char *u = content ? ((const char*(*)(id, SEL))objc_msgSend)(content, sel_registerName("UTF8String")) : 0;
    if (u) {
        char p2[130];
        size_t k = strlen(u);
        if (k > 110) k = 110;
        p2[0] = 'O'; p2[1] = '='; p2[2] = 0;
        memcpy(p2 + 2, u, k);
        p2[2 + k] = 0;
        log_line(p2);
    } else {
        log_line("UNET noparse");
    }
}

static void *boot_thread(void *a) {
    (void)a;
    sleep(1);
    log_init();
    char b[160];
    snprintf(b, sizeof b, "UIPROBE BOOT pid=%d", getpid());
    log_line(b);
    install_hooks();
    net_test();
    return 0;
}

__attribute__((constructor)) static void ctor(void) {
    pthread_t th;
    if (pthread_create(&th, 0, boot_thread, 0) == 0) pthread_detach(th);
    if (pthread_create(&th, 0, ans_thread, 0) == 0) pthread_detach(th);
}
