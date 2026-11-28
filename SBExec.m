//
//  SBExec.m  —  Siri 侧执行层（阶段 7 的「接入」部分）
//
//  模型不再只能说“我做不到”：它输出 {"action":"ui","verb":...,"text":...,...}，
//  由本文件在 SpringBoard 进程内直接调用观察层（SBAxis / SBTouch / SBScreen）执行，
//  结果压成一句简报回灌给模型，模型据此继续下一步或直接回答。
//
//  为什么在进程内而不是走文件命令：
//  Siri 的回答线程就在 SpringBoard 里，写 ax.cmd 再等外部轮询（8~10 秒）没法接受；
//  这里直接调 axHandleLine 的入口，同步拿到结果，单步通常 1~3 秒。
//
//  注意：所有 ObjC 常量仍然禁止（RootHide 下会 SIGBUS），本文件只用纯 C。
//
#import "SiriBridge.h"
#import <stdio.h>
#import <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>

#define EX_OUT_CAP 1400

static void exSleepMs(int ms) {
    if (ms <= 0) return;
    struct timespec ts;
    ts.tv_sec = ms / 1000;
    ts.tv_nsec = (long)(ms % 1000) * 1000000L;
    nanosleep(&ts, NULL);
}

static int exReadFile(const char *path, char *buf, int sz) {
    buf[0] = 0;
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    int n = (int)fread(buf, 1, (size_t)(sz - 1), f);
    fclose(f);
    if (n < 0) n = 0;
    buf[n] = 0;
    // 去掉尾部换行/空格
    while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == '\r' || buf[n - 1] == ' ')) buf[--n] = 0;
    return n;
}

// 从 JSON 里取 "key":"value"（纯字节扫描，与 SBCore 的 sbJsonStr 同思路）
static const char *exJsonStr(const char *json, const char *key, char *buf, int sz) {
    if (!json || !key) return NULL;
    char k[48];
    snprintf(k, sizeof k, "\"%s\"", key);
    const char *p = json;
    while ((p = strstr(p, k))) {
        const char *q = p + strlen(k);
        while (*q == ' ' || *q == '\t' || *q == '\n') q++;
        if (*q != ':') { p = q; continue; }
        q++;
        while (*q == ' ' || *q == '\t' || *q == '\n') q++;
        if (*q != '"') { p = q; continue; }
        q++;
        int n = 0;
        while (*q && *q != '"' && n < sz - 1) {
            if (*q == '\\' && q[1]) q++;
            buf[n++] = *q++;
        }
        buf[n] = 0;
        return buf;
    }
    return NULL;
}

static int exJsonNum(const char *json, const char *key, double *out) {
    if (!json || !key) return 0;
    char k[48];
    snprintf(k, sizeof k, "\"%s\"", key);
    const char *p = strstr(json, k);
    if (!p) return 0;
    const char *q = p + strlen(k);
    while (*q == ' ' || *q == ':' || *q == '\t') q++;
    if (*q != '-' && (*q < '0' || *q > '9')) return 0;
    *out = strtod(q, NULL);
    return 1;
}

static void exSet(char *out, int sz, const char *s) {
    if (!out || sz <= 0) return;
    snprintf(out, (size_t)sz, "%s", s ? s : "");
}

// 把一段文件内容压成一行（去换行/缩进），再截断
static void exFlatten(const char *in, char *out, int sz, int cap) {
    int n = 0;
    for (const char *p = in; *p && n < sz - 1 && n < cap; p++) {
        if (*p == '\n' || *p == '\r' || *p == '\t') continue;
        out[n++] = *p;
    }
    out[n] = 0;
}

// ---------------- 结果文件解析 ----------------

// ax_query.json → 紧凑版：总数 / 命中数 / 前 3 条文案与中心点
static void exCompactFind(const char *file, char *out, int sz) {
    char raw[4096];
    if (!exReadFile(file, raw, (int)sizeof raw)) { exSet(out, sz, "{\"ok\":0,\"err\":\"no-result-file\"}"); return; }
    double total = 0, count = 0;
    exJsonNum(raw, "total", &total);
    exJsonNum(raw, "count", &count);

    char items[600];
    int in = 0;
    items[0] = 0;
    const char *p = raw;
    int shown = 0;
    while (shown < 3 && (p = strstr(p, "\"label\":\""))) {
        p += 9;
        char label[96];
        int n = 0;
        while (*p && *p != '"' && n < 95) {
            if (*p == '\\' && p[1]) p++;
            label[n++] = *p++;
        }
        label[n] = 0;
        const char *c = strstr(p, "\"center\":[");
        double cx = 0, cy = 0;
        if (c) { sscanf(c + 10, "%lf , %lf", &cx, &cy); }
        in += snprintf(items + in, sizeof items - (size_t)in, "%s{\"t\":\"%s\",\"x\":%.1f,\"y\":%.1f}",
                       shown ? "," : "", label, cx, cy);
        if (in >= (int)sizeof items - 80) break;
        shown++;
    }
    snprintf(out, (size_t)sz, "{\"ok\":1,\"total\":%d,\"count\":%d,\"items\":[%s]}",
             (int)total, (int)count, items);
}

// ax_where.json → {"state","pid","app"}
static int exReadWhere(char *state, int stateSz, int *pid, char *app, int appSz) {
    char raw[1024];
    if (!exReadFile(SB_HOME_DIR "/ax_where.json", raw, (int)sizeof raw)) return 0;
    state[0] = 0; app[0] = 0; *pid = 0;
    exJsonStr(raw, "state", state, stateSz);
    exJsonStr(raw, "app", app, appSz);
    double d = 0;
    if (exJsonNum(raw, "pid", &d)) *pid = (int)d;
    return 1;
}

static void exWhereJson(char *out, int sz) {
    char state[16], app[64];
    int pid = 0;
    if (!exReadWhere(state, sizeof state, &pid, app, sizeof app)) {
        exSet(out, sz, "{\"ok\":0,\"err\":\"no-where-file\"}");
        return;
    }
    snprintf(out, (size_t)sz, "{\"ok\":1,\"state\":\"%s\",\"pid\":%d,\"app\":\"%s\"}", state, pid, app);
}

// ---------------- 单步执行 ----------------

static int exRunWhere(char *out, int sz) {
    SBAxisExec("whereami");
    exWhereJson(out, sz);
    return 0;
}

// 前台目标串：优先 App 名，其次 pid
static void exFrontTarget(char *buf, int sz) {
    char state[16], app[64];
    int pid = 0;
    buf[0] = 0;
    if (!exReadWhere(state, sizeof state, &pid, app, sizeof app)) return;
    if (!strcmp(state, "home")) return;
    if (app[0]) snprintf(buf, (size_t)sz, "%s", app);
    else if (pid) snprintf(buf, (size_t)sz, "%d", pid);
}

static int exRunFind(const char *text, const char *appIn, char *out, int sz) {
    char cmd[384], target[96], app[96];
    target[0] = 0;
    if (appIn && appIn[0]) snprintf(app, sizeof app, "%s", appIn);
    else { SBAxisExec("whereami"); exFrontTarget(app, sizeof app); }
    if (!app[0]) { exSet(out, sz, "{\"ok\":0,\"err\":\"no-front-app\"}"); return 0; }
    snprintf(target, sizeof target, "%s", app);
    snprintf(cmd, sizeof cmd, "findq %s label=%s", target, text);
    SBAxisExec(cmd);
    exCompactFind(SB_HOME_DIR "/ax_query.json", out, sz);
    return 0;
}

static int exRunTapq(const char *text, const char *appIn, char *out, int sz) {
    char cmd[384], app[96];
    if (appIn && appIn[0]) snprintf(app, sizeof app, "%s", appIn);
    else { SBAxisExec("whereami"); exFrontTarget(app, sizeof app); }
    if (!app[0]) { exSet(out, sz, "{\"ok\":0,\"err\":\"no-front-app\"}"); return 0; }
    snprintf(cmd, sizeof cmd, "tapq %s label=%s", app, text);
    SBAxisExec(cmd);
    char raw[2048];
    if (!exReadFile(SB_HOME_DIR "/ax_act.json", raw, (int)sizeof raw)) {
        exSet(out, sz, "{\"ok\":0,\"err\":\"no-act-file\"}");
        return 0;
    }
    // 1.8.39：文案同时命中标题/说明文字时（reason=multiple），按面积最大的那个再点一次
    // —— 列表行的 frame 一般铺满屏宽，标题和说明只有一小段，面积最大者就是用户想点的行。
    if (strstr(raw, "\"reason\":\"multiple\"")) {
        SBLogSync("UI tap multiple → pick=area");
        snprintf(cmd, sizeof cmd, "tapq %s label=%s&pick=area", app, text);
        SBAxisExec(cmd);
        if (!exReadFile(SB_HOME_DIR "/ax_act.json", raw, (int)sizeof raw)) {
            exSet(out, sz, "{\"ok\":0,\"err\":\"no-act-file\"}");
            return 0;
        }
    }
    exFlatten(raw, out, sz, EX_OUT_CAP);
    return 0;
}

static int exRunAct(const char *app, const char *text, char *out, int sz) {
    char cmd[384];
    if (!app || !app[0]) { exSet(out, sz, "{\"ok\":0,\"err\":\"need-app\"}"); return 0; }
    if (!text || !text[0]) { exSet(out, sz, "{\"ok\":0,\"err\":\"need-text\"}"); return 0; }
    snprintf(cmd, sizeof cmd, "act %s %s", app, text);
    SBAxisExec(cmd);
    char raw[2048];
    if (!exReadFile(SB_HOME_DIR "/ax_act.json", raw, (int)sizeof raw)) {
        exSet(out, sz, "{\"ok\":0,\"err\":\"no-act-file\"}");
        return 0;
    }
    exFlatten(raw, out, sz, EX_OUT_CAP);
    return 0;
}

static int exRunOpen(const char *app, char *out, int sz) {
    char cmd[320], state[16], name[64];
    int pid = 0;
    if (!app || !app[0]) { exSet(out, sz, "{\"ok\":0,\"err\":\"need-app\"}"); return 0; }
    snprintf(cmd, sizeof cmd, "openapp %s", app);
    SBAxisExec(cmd);
    exSleepMs(4500);
    SBAxisExec("whereami");
    if (!exReadWhere(state, sizeof state, &pid, name, sizeof name)) {
        exSet(out, sz, "{\"ok\":0,\"err\":\"no-where-file\"}");
        return 0;
    }
    int landed = !strcmp(state, "app");
    snprintf(out, (size_t)sz, "{\"ok\":%d,\"state\":\"%s\",\"pid\":%d,\"app\":\"%s\",\"want\":\"%s\"}",
             landed, state, pid, name, app);
    return 0;
}

static int exRunHome(char *out, int sz) {
    SBAxisExec("home2");
    exSleepMs(1000);
    SBAxisExec("whereami");
    char state[16], app[64];
    int pid = 0;
    if (!exReadWhere(state, sizeof state, &pid, app, sizeof app)) {
        exSet(out, sz, "{\"ok\":0,\"err\":\"no-where-file\"}");
        return 0;
    }
    int okk = !strcmp(state, "home");
    snprintf(out, (size_t)sz, "{\"ok\":%d,\"state\":\"%s\"}", okk, state);
    return 0;
}

// 单条 flow 步骤：首词为动词，其余为参数
static int exRunStep(const char *step, char *out, int sz);

static int exRunFlow(const char *stepsCsv, char *out, int sz) {
    if (!stepsCsv || !stepsCsv[0]) { exSet(out, sz, "{\"ok\":0,\"err\":\"need-steps\"}"); return 0; }
    char *copy = strdup(stepsCsv);
    if (!copy) { exSet(out, sz, "{\"ok\":0,\"err\":\"no-mem\"}"); return 0; }
    char acc[EX_OUT_CAP];
    int n = 0, failed = 0, i = 0;
    acc[0] = 0;
    memset(acc, 0, sizeof acc);
    char *save = NULL;
    char *tok = strtok_r(copy, "|", &save);
    while (tok && failed == 0) {
        i++;
        char one[EX_OUT_CAP];
        while (*tok == ' ') tok++;
        exRunStep(tok, one, (int)sizeof one);
        n += snprintf(acc + n, sizeof acc - (size_t)n,
                      "%s{\"i\":%d,\"step\":\"%s\",\"r\":%s}", n ? "," : "", i, tok, one);
        if (!strstr(one, "\"ok\":1")) failed = 1;
        if (n >= (int)sizeof acc - 200) break;
        tok = strtok_r(NULL, "|", &save);
    }
    free(copy);
    snprintf(out, (size_t)sz, "{\"ok\":%d,\"failed\":%d,\"steps\":[%s]}", failed ? 0 : 1, failed, acc);
    return 0;
}

static int exRunStep(const char *step, char *out, int sz) {
    char work[256];
    snprintf(work, sizeof work, "%s", step ? step : "");
    char *verb = work;
    while (*verb == ' ') verb++;
    if (!*verb) { exSet(out, sz, "{\"ok\":0,\"err\":\"empty-step\"}"); return 0; }
    char *rest = strchr(verb, ' ');
    if (rest) { *rest++ = 0; while (*rest == ' ') rest++; }
    else rest = (char *)"";

    if (!strcmp(verb, "where")) return exRunWhere(out, sz);
    if (!strcmp(verb, "home")) return exRunHome(out, sz);
    if (!strcmp(verb, "shot")) {
        int rc = SBScreenShotNow(0, 0, 0);
        snprintf(out, (size_t)sz, "{\"ok\":%d}", rc == 0 ? 1 : 0);
        return 0;
    }
    if (!strcmp(verb, "back")) {
        int rc = SBTouchSwipe(4, 480, 380, 480, 500);
        snprintf(out, (size_t)sz, "{\"ok\":%d,\"gesture\":\"back\"}", rc ? 1 : 0);
        return 0;
    }
    if (!strcmp(verb, "sleep")) {
        exSleepMs(atoi(rest));
        snprintf(out, (size_t)sz, "{\"ok\":1,\"slept\":%d}", atoi(rest));
        return 0;
    }
    if (!strcmp(verb, "swipe")) {
        double a = 0, b = 0, c = 0, d = 0;
        int ms = 500;
        sscanf(rest, "%lf %lf %lf %lf %d", &a, &b, &c, &d, &ms);
        int rc = SBTouchSwipe(a, b, c, d, ms);
        snprintf(out, (size_t)sz, "{\"ok\":%d,\"gesture\":\"swipe\"}", rc ? 1 : 0);
        return 0;
    }
    if (!strcmp(verb, "tap")) {
        // 裸坐标走触摸；写成文案（tap 蓝牙）就走 AX 按文案点击（1.8.40）
        double a = 0, b = 0;
        if (sscanf(rest, "%lf %lf", &a, &b) == 2) {
            int rc = SBTouchTap(a, b);
            snprintf(out, (size_t)sz, "{\"ok\":%d,\"gesture\":\"tap\",\"x\":%.0f,\"y\":%.0f}", rc ? 1 : 0, a, b);
        } else if (rest[0]) {
            return exRunTapq(rest, "", out, sz);
        } else {
            exSet(out, sz, "{\"ok\":0,\"err\":\"need-xy\"}");
        }
        return 0;
    }
    if (!strcmp(verb, "open")) return exRunOpen(rest, out, sz);
    if (!strcmp(verb, "act")) {
        char app[96], text[160];
        app[0] = text[0] = 0;
        sscanf(rest, "%95s %159[^\n]", app, text);
        char *t = text;
        while (*t == ' ') t++;
        return exRunAct(app, t, out, sz);
    }
    if (!strcmp(verb, "find")) {
        char text[256];
        snprintf(text, sizeof text, "%s", rest);
        return exRunFind(text, "", out, sz);
    }
    exSet(out, sz, "{\"ok\":0,\"err\":\"unknown-step\"}");
    return 0;
}

// ---------------- 1.8.37：通用「看屏」与「App 清单」 ----------------

// ax_out.json → 当前前台 App 的可交互元素清单（文案 + 中心点，最多 12 条）
static int exRunElements(char *out, int sz) {
    char state[16], name[64];
    int pid = 0;
    SBAxisExec("whereami");
    if (!exReadWhere(state, sizeof state, &pid, name, sizeof name)) {
        exSet(out, sz, "{\"ok\":0,\"err\":\"no-where-file\"}");
        return 0;
    }
    if (!strcmp(state, "home")) { exSet(out, sz, "{\"ok\":0,\"err\":\"no-front-app\"}"); return 0; }
    if (pid > 0) {
        char cmd[64];
        snprintf(cmd, sizeof cmd, "ap %d", pid);
        SBAxisExec(cmd);
    }
    SBAxisExec("dump");

    char raw[16384];
    if (!exReadFile(SB_HOME_DIR "/ax_out.json", raw, (int)sizeof raw)) {
        exSet(out, sz, "{\"ok\":0,\"err\":\"no-dump-file\"}");
        return 0;
    }
    double totalN = 0;
    int total = 0;
    if (exJsonNum(raw, "count", &totalN)) total = (int)totalN;

    char items[1100];
    int in = 0, shown = 0;
    items[0] = 0;
    const char *p = raw;
    while ((p = strstr(p, "\"label\":\""))) {
        p += 9;
        char label[120];
        int n = 0;
        while (*p && *p != '"' && n < 119) {
            if (*p == '\\' && p[1]) p++;
            label[n++] = *p++;
        }
        label[n] = 0;
        const char *c = strstr(p, "\"center\":[");
        double cx = 0, cy = 0;
        if (c) sscanf(c + 10, "%lf , %lf", &cx, &cy);
        if (!label[0] || n == 0) continue;
        if (shown >= 12 || in >= (int)sizeof items - 160) break;
        in += snprintf(items + in, sizeof items - (size_t)in, "%s{\"t\":\"%s\",\"x\":%.1f,\"y\":%.1f}",
                       shown ? "," : "", label, cx, cy);
        shown++;
    }
    snprintf(out, (size_t)sz, "{\"ok\":1,\"pid\":%d,\"total\":%d,\"count\":%d,\"items\":[%s]}",
             pid, total, shown, items);
    return 0;
}

static int exRunApps(char *out, int sz) {
    SBAxisExec("apps");
    char raw[4096];
    if (!exReadFile(SB_HOME_DIR "/ax_apps.json", raw, (int)sizeof raw)) {
        exSet(out, sz, "{\"ok\":0,\"err\":\"no-apps-file\"}");
        return 0;
    }
    exFlatten(raw, out, sz, 900);
    return 0;
}

// ---------------- 1.8.37：步骤记忆（同一句请求下次直接重放） ----------------

#define EX_ROUTINES SB_HOME_DIR "/routines.txt"
static char g_trace[1024];
static char g_tracePrev[1024];   // 1.8.42：上一轮的步骤，供「保存刚刚步骤」跨轮使用

// 新一轮请求：把本轮步骤降级成「上一轮」，本轮清空。这样用户分两句说
// 「先打开设置点蓝牙」再「保存刚刚步骤」，第二句还能拿到第一句的步骤。
void SBUiTraceReset(void) {
    if (g_trace[0]) {
        snprintf(g_tracePrev, sizeof g_tracePrev, "%s", g_trace);
        g_trace[0] = 0;
    }
}

static void exTraceAdd(const char *s) {
    if (!s || !*s) return;
    size_t n = strlen(g_trace), add = strlen(s);
    // 1.8.40：连续重复的同一步不再追加（连点两次同一行没有意义）
    if (n) {
        const char *last = g_trace + n;
        while (last > g_trace && last[-1] != '|') last--;
        if ((size_t)((g_trace + n) - last) == add && !memcmp(last, s, add)) return;
    }
    if (n + add + 2 >= sizeof g_trace) return;
    if (n) g_trace[n++] = '|';
    memcpy(g_trace + n, s, add + 1);
}

// 读整个 routines.txt（每行 name \t steps）
static int exRoutineLoad(char *buf, int sz) {
    return exReadFile(EX_ROUTINES, buf, sz);
}

static int exRoutineFind(const char *name, char *steps, int sz) {
    char all[4096];
    steps[0] = 0;
    if (!exRoutineLoad(all, (int)sizeof all)) return 0;
    char *save = NULL;
    char *line = strtok_r(all, "\n", &save);
    while (line) {
        char *tab = strchr(line, '\t');
        if (tab) {
            *tab = 0;
            if (!strcmp(line, name)) {
                snprintf(steps, (size_t)sz, "%s", tab + 1);
                return 1;
            }
        }
        line = strtok_r(NULL, "\n", &save);
    }
    return 0;
}

// 保存/覆盖一条步骤（name 与 steps 都做过换行/制表符清洗）
static int exRoutineSave(const char *name, const char *steps) {
    if (!name || !*name || !steps || !*steps) return 0;
    char all[4096], out[4608];
    exRoutineLoad(all, (int)sizeof all);

    // 先按名字过滤掉旧条目
    int kept = 0;
    out[0] = 0;
    char *save = NULL;
    char *line = strtok_r(all, "\n", &save);
    while (line) {
        char *tab = strchr(line, '\t');
        if (tab) {
            *tab = 0;
            if (strcmp(line, name)) {
                int n = (int)strlen(out);
                n += snprintf(out + n, sizeof out - (size_t)n, "%s\t%s\n", line, tab + 1);
                kept++;
            }
        }
        line = strtok_r(NULL, "\n", &save);
    }
    int n = (int)strlen(out);
    snprintf(out + n, sizeof out - (size_t)n, "%s\t%s\n", name, steps);
    FILE *f = fopen(EX_ROUTINES, "w");
    if (!f) return 0;
    fputs(out, f);
    fclose(f);
    SBLogSync("ROUTINE save <%s> kept=%d steps=%s", name, kept, steps);
    return 1;
}

// 名字清单（给系统提示用），形如「看无线、发朋友圈」
id SBRoutineNamesCSV(void) {
    char all[4096];
    if (!exRoutineLoad(all, (int)sizeof all)) return nil;
    char buf[600];
    size_t used = 0;
    int cnt = 0;
    buf[0] = 0;
    char *save = NULL;
    char *line = strtok_r(all, "\n", &save);
    while (line && cnt < 12) {
        char *tab = strchr(line, '\t');
        if (tab) {
            *tab = 0;
            size_t n = strlen(line);
            if (used + n + 4 >= sizeof buf) break;
            if (used) { memcpy(buf + used, "、", 3); used += 3; }
            memcpy(buf + used, line, n);
            used += n;
            buf[used] = 0;
            cnt++;
        }
        line = strtok_r(NULL, "\n", &save);
    }
    if (!cnt) return nil;
    return SBStr(buf);
}

// 把本轮已执行的动作拼成步骤串（供 save 省略 steps 时使用）
static const char *exTrace(void) { return g_trace; }

// 1.8.42：给回灌文本用的上下文——当前前台 App + 本轮已做 + 上一轮做过。
// 模型据此知道「现在在哪个 App、走到第几步」，同一个 App 内多步不至于断片。
int SBUiContextText(char *buf, int sz) {
    if (!buf || sz <= 2) return 0;
    char state[16], name[64];
    int pid = 0;
    SBAxisExec("whereami");
    if (!exReadWhere(state, sizeof state, &pid, name, sizeof name)) {
        snprintf(buf, (size_t)sz, "前台=未知");
        return 0;
    }
    if (!strcmp(state, "home")) snprintf(buf, (size_t)sz, "前台=桌面");
    else snprintf(buf, (size_t)sz, "前台=%s", name);
    int n = (int)strlen(buf);
    if (g_trace[0] && n < sz - 12)
        n += snprintf(buf + n, (size_t)(sz - n), " 本轮=%s", g_trace);
    else if (n < sz - 12)
        n += snprintf(buf + n, (size_t)(sz - n), " 本轮=无");
    if (g_tracePrev[0] && n < sz - 14)
        snprintf(buf + n, (size_t)(sz - n), " 上一轮=%s", g_tracePrev);
    return 1;
}

// 从动作 JSON 里取 "steps"：支持 ["a","b"] 数组，也支持 "a|b" 这种单串（1.8.40）
static void exStepsFromJson(const char *json, char *steps, int sz) {
    steps[0] = 0;
    if (!json) return;
    const char *sp = strstr(json, "\"steps\"");
    if (!sp) return;
    const char *p = strchr(sp, ':');
    if (!p) return;
    p++;
    while (*p == ' ') p++;
    int n = 0;
    if (*p == '[') {
        const char *q = p + 1;
        while (*q && *q != ']' && n < sz - 2) {
            if (*q == '"') {
                q++;
                if (n) steps[n++] = '|';
                while (*q && *q != '"' && n < sz - 2) {
                    if (*q == '\\' && q[1]) q++;
                    steps[n++] = *q++;
                }
                if (*q == '"') q++;
            } else q++;
        }
    } else if (*p == '"') {
        p++;
        while (*p && *p != '"' && n < sz - 1) {
            if (*p == '\\' && p[1]) p++;
            steps[n++] = *p++;
        }
    }
    steps[n] = 0;
}

// 步骤串里连续重复的段去掉（"home|home|open 设置" → "home|open 设置"）
static void exStepsDedupe(const char *in, char *out, int sz) {
    char buf[1200];
    snprintf(buf, sizeof buf, "%s", in ? in : "");
    int n = 0;
    out[0] = 0;
    char *save = NULL;
    char *seg = strtok_r(buf, "|", &save);
    char prev[220];
    prev[0] = 0;
    while (seg) {
        if (seg[0] && strcmp(seg, prev)) {
            n += snprintf(out + n, (size_t)(sz - n), "%s%s", n ? "|" : "", seg);
            snprintf(prev, sizeof prev, "%s", seg);
        }
        seg = strtok_r(NULL, "|", &save);
    }
}

// ---------------- 对外入口 ----------------

// json 是模型下发的那一整行动作对象，例如
// {"action":"ui","verb":"tap","text":"设置"} 或 {"action":"ui","verb":"flow","steps":["open 设置","act 设置 无线局域网"]}
int SBUiExec(const char *json, char *out, int outSz) {
    if (!json || !*json || !out || outSz <= 0) return 0;
    out[0] = 0;
    char verb[32];
    if (!exJsonStr(json, "verb", verb, sizeof verb) || !verb[0]) {
        exSet(out, outSz, "{\"ok\":0,\"err\":\"need-verb\"}");
        return 0;
    }
    char text[256], app[96];
    text[0] = app[0] = 0;
    exJsonStr(json, "text", text, sizeof text);
    exJsonStr(json, "app", app, sizeof app);
    double x = 0, y = 0, x2 = 0, y2 = 0, ms = 500;
    exJsonNum(json, "x", &x);
    exJsonNum(json, "y", &y);
    exJsonNum(json, "x2", &x2);
    exJsonNum(json, "y2", &y2);
    exJsonNum(json, "ms", &ms);

    SBLogSync("UI exec verb=%s text=%s app=%s", verb, text, app);

    // 1.8.37：通用「看」——元素清单与 App 清单，与具体 App 无关
    if (!strcmp(verb, "elements")) { exRunElements(out, outSz); return 0; }
    if (!strcmp(verb, "apps")) { exRunApps(out, outSz); return 0; }
    // 1.8.42：调试用——ctx 看上下文状态，ctxreset 模拟「新一句请求」
    if (!strcmp(verb, "ctx")) {
        char c[900];
        SBUiContextText(c, (int)sizeof c);
        snprintf(out, (size_t)outSz, "{\"ok\":1,\"ctx\":\"%s\"}", c);
        return 0;
    }
    if (!strcmp(verb, "ctxreset")) {
        SBUiTraceReset();
        snprintf(out, (size_t)outSz, "{\"ok\":1,\"reset\":1}");
        return 0;
    }
    if (!strcmp(verb, "routines")) {
        char all[4096], buf[600];
        int in = 0;
        buf[0] = 0;
        if (exRoutineLoad(all, (int)sizeof all)) {
            char *save = NULL;
            char *line = strtok_r(all, "\n", &save);
            while (line && in < (int)sizeof buf - 80) {
                char *tab = strchr(line, '\t');
                if (tab) {
                    *tab = 0;
                    in += snprintf(buf + in, sizeof buf - (size_t)in, "%s\"%s\"", in ? "," : "", line);
                }
                line = strtok_r(NULL, "\n", &save);
            }
        }
        snprintf(out, (size_t)outSz, "{\"ok\":1,\"routines\":[%s]}", buf);
        return 0;
    }
    if (!strcmp(verb, "save")) {
        char name[64], steps[1024], norm[1200];
        name[0] = steps[0] = 0;
        exJsonStr(json, "name", name, sizeof name);
        exStepsFromJson(json, steps, (int)sizeof steps);
        // 没给 steps：优先本轮轨迹；本轮为空就退回上一轮轨迹（用户分两句说的情况）
        int fromPrev = 0;
        if (!steps[0]) {
            snprintf(steps, sizeof steps, "%s", exTrace());
            if (!steps[0]) { snprintf(steps, sizeof steps, "%s", g_tracePrev); fromPrev = 1; }
        }
        if (!name[0] || !steps[0]) {
            exSet(out, outSz, "{\"ok\":0,\"err\":\"need-name-and-steps\"}");
            return 0;
        }
        exStepsDedupe(steps, norm, (int)sizeof norm);
        int okk = exRoutineSave(name, norm);
        snprintf(out, (size_t)outSz, "{\"ok\":%d,\"saved\":\"%s\",\"steps\":\"%s\"}", okk, name, norm);
        return 0;
    }
    if (!strcmp(verb, "run")) {
        char name[64], steps[1024];
        name[0] = 0;
        exJsonStr(json, "name", name, sizeof name);
        if (!name[0]) { exSet(out, outSz, "{\"ok\":0,\"err\":\"need-name\"}"); return 0; }
        if (!exRoutineFind(name, steps, (int)sizeof steps)) {
            snprintf(out, (size_t)outSz, "{\"ok\":0,\"err\":\"no-routine\",\"name\":\"%s\"}", name);
            return 0;
        }
        exRunFlow(steps, out, outSz);
        return 0;
    }

    // 动作类：成功才记进轨迹，供 save 使用
    char step[220];
    step[0] = 0;
    if (!strcmp(verb, "open")) snprintf(step, sizeof step, "open %s", app);
    else if (!strcmp(verb, "tap")) snprintf(step, sizeof step, "tap %s", text);
    else if (!strcmp(verb, "act")) snprintf(step, sizeof step, "act %s %s", app, text);
    else if (!strcmp(verb, "tapxy")) snprintf(step, sizeof step, "tap %.0f %.0f", x, y);
    else if (!strcmp(verb, "swipe")) snprintf(step, sizeof step, "swipe %.0f %.0f %.0f %.0f %d", x, y, x2, y2, (int)ms);
    else if (!strcmp(verb, "home")) snprintf(step, sizeof step, "home");
    else if (!strcmp(verb, "back")) snprintf(step, sizeof step, "back");

    if (!strcmp(verb, "where")) { exRunWhere(out, outSz); return 0; }
    if (!strcmp(verb, "home")) { exRunHome(out, outSz); goto trace; }
    if (!strcmp(verb, "shot")) {
        int rc = SBScreenShotNow(0, 0, 0);
        snprintf(out, (size_t)outSz, "{\"ok\":%d,\"verb\":\"shot\"}", rc == 0 ? 1 : 0);
        return 0;
    }
    if (!strcmp(verb, "find")) { exRunFind(text, app, out, outSz); return 0; }
    if (!strcmp(verb, "tap")) { exRunTapq(text, app, out, outSz); goto trace; }
    if (!strcmp(verb, "act")) { exRunAct(app, text, out, outSz); goto trace; }
    if (!strcmp(verb, "open")) { exRunOpen(app, out, outSz); goto trace; }
    if (!strcmp(verb, "back")) {
        int rc = SBTouchSwipe(4, 480, 380, 480, 500);
        snprintf(out, (size_t)outSz, "{\"ok\":%d,\"verb\":\"back\"}", rc ? 1 : 0);
        goto trace;
    }
    if (!strcmp(verb, "swipe")) {
        int rc = SBTouchSwipe(x, y, x2, y2, (int)ms);
        snprintf(out, (size_t)outSz, "{\"ok\":%d,\"verb\":\"swipe\"}", rc ? 1 : 0);
        goto trace;
    }
    if (!strcmp(verb, "tapxy")) {
        int rc = SBTouchTap(x, y);
        snprintf(out, (size_t)outSz, "{\"ok\":%d,\"verb\":\"tapxy\",\"x\":%.0f,\"y\":%.0f}", rc ? 1 : 0, x, y);
        goto trace;
    }
    if (!strcmp(verb, "flow")) {
        char steps[1024], norm[1200];
        exStepsFromJson(json, steps, (int)sizeof steps);
        exStepsDedupe(steps, norm, (int)sizeof norm);
        exRunFlow(norm, out, outSz);
        return 0;
    }
    if (!strcmp(verb, "ocr")) {
        exSet(out, outSz, "{\"ok\":0,\"err\":\"no-ocr-on-device\",\"hint\":\"识屏在 PC 侧；设备内只能用 elements/find/tap\"}");
        return 0;
    }
    snprintf(out, (size_t)outSz, "{\"ok\":0,\"err\":\"unknown-verb\",\"verb\":\"%s\"}", verb);
    return 0;

trace:
    if (step[0] && strstr(out, "\"ok\":1")) exTraceAdd(step);
    return 0;
}
