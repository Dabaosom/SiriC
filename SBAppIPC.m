#import "SiriBridge.h"
#include <string.h>
#include <dispatch/dispatch.h>

// 1.6.26：跨进程第一步 —— 从 SpringBoard 探一次 App 侧端口。
// 只发 ping、只拿回 VC 类名和视图数量，不操作任何控件；目的是把
// 「SpringBoard → IPC → App 进程」这条线先接通并可观测。
#define SBAPP_PORT "com.doubao.sbapp.port"

void SBAppPingAsync(const char *why) {
    const char *w = why ? why : "";
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        CFMessagePortRef remote = CFMessagePortCreateRemote(NULL, CFSTR(SBAPP_PORT));
        if (!remote) {
            SBLogSync("APP port none (%s)", w);
            return;
        }
        const char *req = "ping";
        CFDataRef d = CFDataCreate(NULL, (const UInt8 *)req, (CFIndex)strlen(req));
        CFDataRef rep = NULL;
        // 后台线程里同步等 0.4 秒，不碰主线程；微信没在前台时就落在这个超时上。
        SInt32 rc = CFMessagePortSendRequest(remote, 1, d, 0.4, 0.4,
                                             kCFRunLoopDefaultMode, &rep);
        if (d) CFRelease(d);
        if (rc == kCFMessagePortSuccess && rep) {
            CFIndex n = CFDataGetLength(rep);
            char buf[256];
            if (n > (CFIndex)sizeof(buf) - 1) n = sizeof(buf) - 1;
            CFDataGetBytes(rep, CFRangeMake(0, n), (UInt8 *)buf);
            buf[n] = 0;
            SBLogSync("APP pong <%s> (%s)", buf, w);
            CFRelease(rep);
        } else {
            SBLogSync("APP send rc=%d (%s)", (int)rc, w);
        }
        CFRelease(remote);
    });
}
