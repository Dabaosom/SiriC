#import "SiriBridge.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>
#include <pthread.h>
#include <fcntl.h>
#include <dirent.h>

//  快捷指令分支（1.5.7）
//  设备上有 SpringCuts（/usr/bin/springcuts），接口实测：
//    springcuts -l          列出全部快捷指令名（每行末尾带一个逗号）
//    springcuts -r "名字" -w -i   后台、不可见、等执行完并返回退出码
//  从 SSH（root、无前台 App）实测 "更换微信" 成功 exit=0，证明后台可跑通。
//  这里不经过 AI：命中名字就直接执行，然后用一条自造 ACE 报结果。

extern char **environ;

// RootHide：SpringBoard 看到的是真实 rootfs，/usr/bin/springcuts 在它眼里不存在
// （实测 posix_spawn rc=2 ENOENT）。真正的二进制在
// /var/containers/Bundle/Application/.jbroot-XXXX/usr/bin/springcuts，启动时扫一次并缓存。
static char g_scPathBuf[512];

static const char *sbScPath(void) {
    if (g_scPathBuf[0]) return g_scPathBuf;
    const char *cands[] = {
        "/var/containers/Bundle/Application/.jbroot-E47CB259E94FA376/usr/bin/springcuts",
        "/usr/bin/springcuts",
        NULL
    };
    for (int i = 0; cands[i]; i++) {
        if (access(cands[i], X_OK) == 0) {
            strncpy(g_scPathBuf, cands[i], sizeof(g_scPathBuf) - 1);
            SBLogSync("SC path %s", g_scPathBuf);
            return g_scPathBuf;
        }
        SBLogSync("SC path miss %s", cands[i]);
    }
    // 兜底：扫 .jbroot-* 目录名
    DIR *d = opendir("/var/containers/Bundle/Application");
    if (d) {
        struct dirent *e;
        while ((e = readdir(d))) {
            if (strncmp(e->d_name, ".jbroot-", 8) != 0) continue;
            char p[512];
            snprintf(p, sizeof(p), "/var/containers/Bundle/Application/%s/usr/bin/springcuts", e->d_name);
            if (access(p, X_OK) == 0) {
                strncpy(g_scPathBuf, p, sizeof(g_scPathBuf) - 1);
                SBLogSync("SC path scan %s", g_scPathBuf);
                break;
            }
        }
        closedir(d);
    }
    if (!g_scPathBuf[0]) SBLogSync("SC path none");
    return g_scPathBuf[0] ? g_scPathBuf : NULL;
}

#define SB_MAXSC 400
static char *g_scNames[SB_MAXSC];
static int g_scCount = -1;   // -1 未枚举

static const char *kScTrigger[] = { "快捷指令", "捷径", "快捷方式", NULL };
static const char *kScPrefix[]  = { "运行", "执行", "跑一下", "跑一跑", "启动", "触发", NULL };

static void sbScParseLine(char *line) {
    // 去行尾空白与逗号
    size_t n = strlen(line);
    while (n && (line[n-1] == '\n' || line[n-1] == '\r' || line[n-1] == ' ' || line[n-1] == '\t' || line[n-1] == ',')) line[--n] = 0;
    if (n < 2) return;
    if (!strcmp(line, "Shortcut names:")) return;
    if (g_scCount >= SB_MAXSC) return;
    for (int i = 0; i < g_scCount; i++) if (!strcmp(g_scNames[i], line)) return;
    char *cp = strdup(line);
    if (cp) g_scNames[g_scCount++] = cp;
}

void *SBShortcutLoadThreadMain(void *p);

void SBShortcutLoad(void) {
    if (g_scCount >= 0) return;
    g_scCount = 0;
    SBLogSync("SC load begin");
    int fds[2] = { -1, -1 };
    if (pipe(fds) != 0) { SBLogSync("SC list pipe fail"); return; }

    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, fds[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&fa, fds[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&fa, fds[0]);
    posix_spawn_file_actions_addclose(&fa, fds[1]);

    const char *sp = sbScPath();
    if (!sp) { close(fds[0]); SBLogSync("SC list nopath"); return; }
    char *argv[] = { (char *)sp, "-l", NULL };
    pid_t pid = 0;
    int rc = posix_spawn(&pid, sp, &fa, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&fa);
    close(fds[1]);
    if (rc != 0) { close(fds[0]); SBLogSync("SC list spawn rc=%d", rc); return; }

    char buf[4096];
    char cur[256];
    size_t cl = 0;
    ssize_t r;
    while ((r = read(fds[0], buf, sizeof(buf) - 1)) > 0) {
        for (ssize_t i = 0; i < r; i++) {
            char ch = buf[i];
            if (ch == '\n') {
                cur[cl] = 0;
                sbScParseLine(cur);
                cl = 0;
            } else if (cl + 1 < sizeof(cur)) {
                cur[cl++] = ch;
            }
        }
    }
    cur[cl] = 0;
    sbScParseLine(cur);
    close(fds[0]);
    int st = 0; waitpid(pid, &st, 0);
    SBLogSync("SC list count=%d", g_scCount);
}

void *SBShortcutLoadThreadMain(void *p) {
    (void)p;
    SBShortcutLoad();
    return NULL;
}

// 返回匹配到的名字（指针在缓存里，勿释放）；无匹配返回 NULL。
static const char *sbScFindName(const char *s) {
    const char *best = NULL;
    size_t bestLen = 0;
    for (int i = 0; i < g_scCount; i++) {
        const char *nm = g_scNames[i];
        if (!nm) continue;
        size_t n = strlen(nm);
        if (n < 2 || n <= bestLen) continue;
        if (strstr(s, nm)) { best = nm; bestLen = n; }
    }
    return best;
}

typedef struct { id conn; char *text; int wait; int base; int noWait; } SBScJob;

static void sbScFinish(void *p) {
    SBScJob *j = (SBScJob *)p;
    // 原生那条回答还没到，就先别提交：等它被吞下来再上屏，避免先答后原生再补一句。
    if (!j->noWait && j->wait < 20 && SBShimSwallowCount() <= j->base) {
        j->wait++;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(100 * NSEC_PER_MSEC)),
                       dispatch_get_main_queue(),
                       ^{ sbScFinish(j); });
        return;
    }
    SBAISetPending(NO);
    SBLogSync("SC submit %s", j->text);
    id t = SBStr(j->text);
    if (t) {
        id cmd = SBAceAddViews(t);
        if (cmd) SBSubmitAce(cmd, j->conn);
        id tts = SBAcePreSynthTTS(t);
        if (tts) SBSubmitAce(tts, j->conn);
    }
    SBMsgC(j->conn, "release");
    free(j->text);
    free(j);
}

static void *sbScThread(void *p) {
    SBScJob *j = (SBScJob *)p;
    const char *name = NULL;
    // 名字单独带过去：由 SBShortcutTry 存进 text 段之后，用第二个字段
    // 这里约定 j->text 先放 "名字"，跑完再改写为结果文本。
    name = j->text;

    const char *sp = sbScPath();
    char *argv[] = { (char *)sp, "-r", (char *)name, "-w", "-i", NULL };
    pid_t pid = 0;
    int rc = (sp ? posix_spawn(&pid, sp, NULL, NULL, argv, environ) : 2);
    int code = -1;
    if (rc == 0) {
        int st = 0;
        if (waitpid(pid, &st, 0) == pid) code = WIFEXITED(st) ? WEXITSTATUS(st) : -1;
    }
    SBLogSync("SC run %s rc=%d exit=%d", name, rc, code);

    char *msg = calloc(1, 300);
    if (msg) {
        if (rc == 0 && code == 0) snprintf(msg, 300, "已运行快捷指令「%s」", name);
        else if (rc != 0) snprintf(msg, 300, "快捷指令「%s」启动失败", name);
        else snprintf(msg, 300, "快捷指令「%s」运行失败，错误码 %d", name, code);
    }
    free(j->text);
    j->text = msg ? msg : strdup("快捷指令运行结束");
    dispatch_async_f(dispatch_get_main_queue(), j, sbScFinish);
    return NULL;
}

// 把已缓存的快捷指令名拼成一行（给 AI 的系统提示用），最多 40 条。
id SBShortcutNamesCSV(void) {
    SBShortcutLoad();
    if (g_scCount <= 0) return nil;
    char buf[2048];
    buf[0] = 0;
    size_t used = 0;
    for (int i = 0; i < g_scCount && i < 40; i++) {
        size_t n = strlen(g_scNames[i]);
        if (used + n + 2 >= sizeof(buf)) break;
        if (used) { buf[used++] = 0xE3; buf[used++] = 0x80; buf[used++] = 0x81; } // 、U+3001
        memcpy(buf + used, g_scNames[i], n);
        used += n;
    }
    buf[used] = 0;
    SBLogSync("SC csv len=%lu", (unsigned long)used);
    return SBStr(buf);
}

// 语音里命中快捷指令名 → 直接执行（不经 AI）。命中返回 YES。
BOOL SBShortcutTry(id text, id conn) {
    if (!text || !conn) return NO;
    const char *s = (const char *)SBMsgC(text, "UTF8String");
    if (!s || !*s) return NO;
    s = SBStripWake(s);
    if (!*s) return NO;

    SBShortcutLoad();

    int explicitSc = 0;
    for (int i = 0; kScTrigger[i]; i++) if (strstr(s, kScTrigger[i])) { explicitSc = 1; break; }
    int hasPrefix = 0;
    for (int i = 0; kScPrefix[i]; i++) {
        if (strncmp(s, kScPrefix[i], strlen(kScPrefix[i])) == 0) { hasPrefix = 1; break; }
    }

    const char *name = NULL;
    if (g_scCount > 0) {
        name = sbScFindName(s);
        // 精确整句就是名字（如「更换微信」），也认
        if (!name) {
            for (int i = 0; i < g_scCount; i++) {
                if (!strcmp(g_scNames[i], s)) { name = g_scNames[i]; break; }
            }
        }
    }
    if (!name) {
        if (explicitSc) SBLog("SC hit keyword noname");
        return NO;
    }
    if (!explicitSc && !hasPrefix) {
        // 没有明确触发词的普通句子（比如问「微信怎么换头像」里恰好含名字）不抢
        return NO;
    }

    SBLogSync("SC hit %s", name);
    return SBShortcutRunNamed(name, conn);
}

// 直接按名字跑（语音精确匹配与 AI 结构化指令共用这一条）。
// noWait=1：AI 触发的场景里，原生那条 AddViews 早就被吞掉了，不用再等。
BOOL SBShortcutRunNamed(const char *name, id conn) {
    if (!name || !*name || !conn) return NO;
    SBAISetPending(YES);
    SBScJob *j = calloc(1, sizeof(SBScJob));
    if (!j) { SBAISetPending(NO); return NO; }
    j->conn = SBMsgC(conn, "retain");
    j->text = strdup(name);
    j->base = SBShimSwallowCount();
    j->noWait = 1;

    pthread_t th;
    if (pthread_create(&th, NULL, sbScThread, j) != 0) {
        SBLogSync("SC thread fail");
        SBMsgC(j->conn, "release");
        free(j->text);
        free(j);
        SBAISetPending(NO);
        return NO;
    }
    pthread_detach(th);
    return YES;
}
