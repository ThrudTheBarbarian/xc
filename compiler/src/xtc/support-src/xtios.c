// xtios.c — the iOS platform shim (iOS.md stage 4), plain C on purpose: it is
// generated into support/ios/runtime/xtios-sim.s and xtios.s and assembled by
// the in-house assembler, which speaks clang's C output and not Objective-C's
// metadata sections. What the platform layer needs from the OS lands here.
//
//   simulator:  clang -S -O1 -target arm64-apple-ios15.0-simulator -isysroot $(xcrun -sdk iphonesimulator --show-sdk-path)
//                     -fno-stack-protector -fomit-frame-pointer -fno-asynchronous-unwind-tables -fno-jump-tables -mgeneral-regs-only
//                     -o support/ios/runtime/xtios-sim.s src/xtc/support-src/xtios.c
//   device:     the same with -target arm64-apple-ios15.0 and -sdk iphoneos, -o support/ios/runtime/xtios.s
//   (-mgeneral-regs-only: no float/SIMD in this file, so clang cannot zero a
//   struct with a NEON store the in-house assemblers do not take.)
//   then, in both: perl -pi -e 's/\bLBB(\d)/LIOSBB$1/g; s/\bLloh(\d)/LIOSloh$1/g; s/\bLCPI(\d)/LIOSCPI$1/g; s/\bL_\.str/LIOS_.str/g; s/\bl_\.str/lios_.str/g'
//   — clang restarts its local-label numbering per file, and this file is
//   concatenated after rt-macos.s (another clang emission) before it is
//   assembled, so its LBB/Lloh labels must not collide (the assembler
//   refuses a duplicate label, rightly).
//
// _xt_ios_log: the unified log — syslog(3) is the C door to it (os_log's
// macros need format data the assembler would have to carry). The console
// copy is the prelude's ConsoleLogger, so the program's output is what it is
// on macOS; this adds the line to `log stream` / Console.app.
// _xt_ios_fetch: Url.fetch's transport — NSURLSession, driven from C through
// objc_msgSend with a hand-laid stack block for the completion handler and
// a dispatch semaphore to make it synchronous (Url.complete fires inline,
// exactly as the generic no-delegate path does). Every scheme NSURLSession
// speaks: file://, http://, https://.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <syslog.h>

void _xt_ios_log(uint32_t level, const char* msg)
    {
    int pri = level == 2 ? LOG_ERR : (level == 1 ? LOG_WARNING : LOG_NOTICE);
    syslog(pri, "%s", msg);
    }

// ── NSURLSession from C ────────────────────────────────────────────────
typedef void* id;
typedef void* SEL;
extern id objc_getClass(const char* name);
extern SEL sel_registerName(const char* name);
extern id objc_msgSend(id self, SEL op, ...);
extern void* _NSConcreteStackBlock[32];
typedef void* dispatch_semaphore_t;
extern dispatch_semaphore_t dispatch_semaphore_create(long value);
extern long dispatch_semaphore_wait(dispatch_semaphore_t dsema, uint64_t timeout);
extern long dispatch_semaphore_signal(dispatch_semaphore_t dsema);
#define DISPATCH_TIME_FOREVER (~0ull)

// The completion handler, as the blocks ABI lays it out: isa, flags,
// reserved, invoke, descriptor, then the captures. No copy/dispose helpers
// (flags 0): the captures are plain pointers, so the runtime's Block_copy
// memcpy is the right thing when NSURLSession keeps the block.
struct xt_fetch_result
    {
    uint8_t* body;
    uint32_t len;
    uint32_t status;
    int done;
    dispatch_semaphore_t sem;
    };
struct xt_blk_desc
    {
    unsigned long reserved;
    unsigned long size;
    };
struct xt_blk
    {
    void* isa;
    int flags;
    int reserved;
    void (*invoke)(struct xt_blk*, id, id, id);
    struct xt_blk_desc* desc;
    struct xt_fetch_result* r;
    };

static void xt_fetch_done(struct xt_blk* blk, id data, id response, id error)
    {
    struct xt_fetch_result* r = blk->r;
    r->status = 0;
    r->body = NULL;
    r->len = 0;
    if (data && !error)
        {
        uint32_t n = (uint32_t)((unsigned long (*)(id, SEL))objc_msgSend)(data, sel_registerName("length"));
        const uint8_t* p = ((const uint8_t* (*)(id, SEL))objc_msgSend)(data, sel_registerName("bytes"));
        r->body = malloc(n + 1);
        if (r->body)
            {
            if (n)
                memcpy(r->body, p, n);
            r->body[n] = 0;
            r->len = n;
            }
        // An HTTP response carries its status; a file: response is not HTTP —
        // 200 when the read succeeded, as the generic contract expects.
        r->status = 200;
        if (response)
            {
            id http = objc_getClass("NSHTTPURLResponse");
            int isHttp = (int)((long (*)(id, SEL, id))objc_msgSend)(response, sel_registerName("isKindOfClass:"), http);
            if (isHttp)
                r->status = (uint32_t)((long (*)(id, SEL))objc_msgSend)(response, sel_registerName("statusCode"));
            }
        }
    r->done = 1;
    dispatch_semaphore_signal(r->sem);
    }

// The body's release, under the shim's own name: the prelude must not declare
// `free` itself — a program (uxkit's UXLibc.xc) may declare libc's free with
// its own spelling, and a C symbol has exactly one signature.
void _xt_ios_free(uint8_t* p)
    {
    free(p);
    }

// Fetch `url` synchronously. Returns the body (malloc'd, NUL-terminated, or
// NULL) and sets *status (0 on failure) and *len.
uint8_t* _xt_ios_fetch(const char* url, uint32_t* status, uint32_t* len)
    {
    *status = 0;
    *len = 0;
    id nsstr = ((id (*)(id, SEL, const char*))objc_msgSend)(objc_getClass("NSString"), sel_registerName("stringWithUTF8String:"), url);
    id nsurl = ((id (*)(id, SEL, id))objc_msgSend)(objc_getClass("NSURL"), sel_registerName("URLWithString:"), nsstr);
    if (!nsurl)
        return NULL;
    id session = ((id (*)(id, SEL))objc_msgSend)(objc_getClass("NSURLSession"), sel_registerName("sharedSession"));
    struct xt_fetch_result r = {NULL, 0, 0, 0, dispatch_semaphore_create(0)};
    struct xt_blk_desc desc = {0, sizeof(struct xt_blk)};
    struct xt_blk blk = {_NSConcreteStackBlock, 0, 0, xt_fetch_done, &desc, &r};
    id task = ((id (*)(id, SEL, id, void*))objc_msgSend)(session, sel_registerName("dataTaskWithURL:completionHandler:"), nsurl, &blk);
    if (!task)
        return NULL;
    ((void (*)(id, SEL))objc_msgSend)(task, sel_registerName("resume"));
    dispatch_semaphore_wait(r.sem, DISPATCH_TIME_FOREVER);
    *status = r.status;
    *len = r.len;
    return r.body;
    }
