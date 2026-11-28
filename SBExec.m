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
        // flow 里的 tap 是裸坐标；文案点击请用 verb=tap（AX 模式）
        double a = 0, b = 0;
        if (sscanf(rest, "%lf %lf", &a, &b) == 2) {
            int rc = SBTouchTap(a, b);
            snprintf(out, (size_t)sz, "{\"ok\":%d,\"gesture\":\"tap\",\"x\":%.0f,\"y\":%.0f}", rc ? 1 : 0, a, b);
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

    if (!strcmp(verb, "where")) return exRunWhere(out, outSz);
    if (!strcmp(verb, "home")) return exRunHome(out, outSz);
    if (!strcmp(verb, "shot")) {
        int rc = SBScreenShotNow(0, 0, 0);
        snprintf(out, (size_t)outSz, "{\"ok\":%d,\"verb\":\"shot\"}", rc == 0 ? 1 : 0);
        return 0;
    }
    if (!strcmp(verb, "find")) return exRunFind(text, app, out, outSz);
    if (!strcmp(verb, "tap")) return exRunTapq(text, app, out, outSz);
    if (!strcmp(verb, "act")) return exRunAct(app, text, out, outSz);
    if (!strcmp(verb, "open")) return exRunOpen(app, out, outSz);
    if (!strcmp(verb, "back")) {
        int rc = SBTouchSwipe(4, 480, 380, 480, 500);
        snprintf(out, (size_t)outSz, "{\"ok\":%d,\"verb\":\"back\"}", rc ? 1 : 0);
        return 0;
    }
    if (!strcmp(verb, "swipe")) {
        int rc = SBTouchSwipe(x, y, x2, y2, (int)ms);
        snprintf(out, (size_t)outSz, "{\"ok\":%d,\"verb\":\"swipe\"}", rc ? 1 : 0);
        return 0;
    }
    if (!strcmp(verb, "tapxy")) {
        int rc = SBTouchTap(x, y);
        snprintf(out, (size_t)outSz, "{\"ok\":%d,\"verb\":\"tapxy\",\"x\":%.0f,\"y\":%.0f}", rc ? 1 : 0, x, y);
        return 0;
    }
    if (!strcmp(verb, "flow")) {
        char steps[1024];
        steps[0] = 0;
        const char *sp = strstr(json, "\"steps\"");
        if (sp) {
            const char *lb = strchr(sp, '[');
            if (lb) {
                int n = 0;
                const char *q = lb + 1;
                while (*q && *q != ']' && n < (int)sizeof steps - 2) {
                    if (*q == '"') {
                        q++;
                        if (n) steps[n++] = '|';
                        while (*q && *q != '"' && n < (int)sizeof steps - 2) {
                            if (*q == '\\' && q[1]) q++;
                            steps[n++] = *q++;
                        }
                        if (*q == '"') q++;
                    } else q++;
                }
                steps[n] = 0;
            }
        }
        return exRunFlow(steps, out, outSz);
    }
    if (!strcmp(verb, "ocr")) {
        exSet(out, outSz, "{\"ok\":0,\"err\":\"no-ocr-on-device\",\"hint\":\"识屏在 PC 侧；设备内只能用 find/tap(AX)\"}");
        return 0;
    }
    snprintf(out, (size_t)outSz, "{\"ok\":0,\"err\":\"unknown-verb\",\"verb\":\"%s\"}", verb);
    return 0;
}
