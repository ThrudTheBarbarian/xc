#import <Foundation/Foundation.h>
#import "XTWasmWriter.h"

// xcc-ln-wasm32 — WAT → <out>.wasm + <out>.js, in-house.
//
// The "link" step of the wasm32 pipeline: assembles the WAT text that
// xcc-cg-wasm32 emitted (XTWasmWriter — no wat2wasm, no external tools; an
// in-house failure is a HARD error) and writes the universal JS loader
// beside the module, so `xcc -A wasm32 -o prog prog.xc` yields prog.wasm +
// prog.js, runnable with `node prog.js` and loadable in a browser as either
// a classic script or a module (the .wasm resolves beside the page).
//
// Library mode (W2, `xcc --emit-lib -A wasm32`): --emit-lib writes
// <out>.wasm (with the `.xtc.iface` interface JSON embedded as a wasm
// CUSTOM section, the same role the ELF section plays) plus the
// <out>.json sidecar {dataSize, tableSize, deps} the loader reads —
// and NO .js/.html (a library is instantiated by its app's loader).
// --dep <name> (repeatable) names an imported library. In an app the names
// are baked into <out>.js, and its loader instantiates lib<name>.wasm beside
// the app with the app's memory/table/runtime wired through. In a library
// they are the sidecar's `deps`, which the loader follows to load the
// libraries an app does not import itself, and to set each library up
// before the libraries that import it.
//
// Usage:
//   xcc-ln-wasm32 <input.wat> <output-base> [-q] [--emit-lib]
//                 [--iface <json-path>] [--dep <name>]...

#ifndef XTC_VERSION
#define XTC_VERSION "0.0"
#endif

// The loader: one file that runs under Node (CommonJS), in a browser, and —
// when the page opts in with globalThis.xccConfig = { runLoop: "worker" } —
// as its own Web Worker (the same file detects which role it is playing).
// The host surface is the `env` package; anything the module imports that
// the loader doesn't provide fails AT INSTANTIATION with a message naming
// the import (the Proxy), not at call time deep inside the program.
//
// Worker mode is the compiler-side half of the Xtg web run loop
// (Rocks/doc/XG-WEB-BACKEND.md sec 3, wasm-target.md sec 12.2 option 3):
// the MAIN thread owns the DOM/canvas and pushes normalized events into a
// JS-allocated SharedArrayBuffer ring; the WORKER instantiates the module
// (its own linear memory stays NON-shared — no atomic-ARC forcing, sec 3.1)
// and blocks on Atomics.wait. Needs COOP/COEP headers to get a SAB.
//
// Ring contract (i32 indices into the SAB):
//   [0] writeSeq   — main-thread-owned, monotonic
//   [1] readSeq    — worker-owned; write-read >= capacity drops the OLDEST
//   [2] replySeq / [3] replyValue — the blocking worker->main request lane
//   [8...] event slots, 8 x i32 each: [type,a,b,c,d,e,f,g]
// Default main-side listeners push: 1 mousedown 2 mouseup 3 mousemove
// (x,y,button) 4 keydown 5 keyup (keyCode). The page can push anything via
// globalThis.xccPushEvent(type,a,...). Worker-side env primitives:
//   _xt_ring_wait(timeoutMs) -> 0 timed-out / 1 event pending
//   _xt_ring_read(ptr)       -> event type or -1; copies 8 i32s to ptr
//   _xt_req_block(kind,a,b,c)-> i32 reply from globalThis.xccOnRequest
// and, for a host package's worker shim, globalThis.xccRequest(kind, payload)
// (blocking, structured payload) and globalThis.xccPost(payload) (to the
// page's globalThis.xccOnMessage).
static NSString* _Nullable loaderJS(NSString* baseName, NSArray<NSString*>* deps, NSString* _Nullable templatePath)
    {
    NSString* fromTree = templatePath ? [NSString stringWithContentsOfFile:templatePath
                                                                  encoding:NSUTF8StringEncoding
                                                                     error:NULL]
                                      : nil;
    if (!fromTree)
        return nil;
    NSString* t = fromTree;
    t = [t stringByReplacingOccurrencesOfString:@"__BASE__" withString:baseName];
    NSMutableArray<NSString*>* quoted = [NSMutableArray array];
    for (NSString* d in deps)
        [quoted addObject:[NSString stringWithFormat:@"\"%@\"", d]];
    return [t stringByReplacingOccurrencesOfString:@"__DEPS__"
                                        withString:[NSString stringWithFormat:@"[%@]",
                                                                              [quoted componentsJoinedByString:@", "]]];
    }

// A starter page: stdout into a <pre> via the loader's xccOut hook. Written
// only when absent — customised pages must survive a rebuild (the .js and
// .wasm regenerate every build; the page is the user's).
static NSString* starterHTML(NSString* baseName)
    {
    return [NSString stringWithFormat:
                         @"<!doctype html>\n"
                         @"<!-- Generated once by xcc-ln-wasm32 for %@.wasm — edit freely; a rebuild\n"
                         @"     rewrites %@.js and %@.wasm but leaves this page alone. -->\n"
                         @"<html lang=\"en\">\n"
                         @"<head>\n"
                         @"<meta charset=\"utf-8\">\n"
                         @"<title>%@</title>\n"
                         @"<style>\n"
                         @"  body { background: #1e1e1e; color: #d4d4d4; font: 14px/1.5 ui-monospace, monospace;\n"
                         @"         margin: 2rem; }\n"
                         @"  pre  { white-space: pre-wrap; }\n"
                         @"</style>\n"
                         @"</head>\n"
                         @"<body>\n"
                         @"<h1>%@</h1>\n"
                         @"<pre id=\"out\"></pre>\n"
                         @"<script>\n"
                         @"  const out = document.getElementById(\"out\");\n"
                         @"  globalThis.xccOut = (line) => { out.textContent += line + \"\\n\"; };\n"
                         @"  // Host packages (#package): define before the loader runs, e.g.\n"
                         @"  // globalThis.xccImports = { js: { jsPing: (v) => console.log(v) } };\n"
                         @"</script>\n"
                         @"<script src=\"%@.js\"></script>\n"
                         @"</body>\n"
                         @"</html>\n",
                         baseName, baseName, baseName, baseName, baseName, baseName];
    }

int main(int argc, const char* argv[])
    {
    @autoreleasepool
        {
        NSString *inPath = nil, *outBase = nil, *ifacePath = nil, *loaderPath = nil;
        NSMutableArray<NSString*>* deps = [NSMutableArray array];
        BOOL quiet = NO, emitLib = NO;
        for (int i = 1; i < argc; i++)
            {
            NSString* a = @(argv[i]);
            if ([a isEqualToString:@"-v"] || [a isEqualToString:@"--version"])
                {
                printf("xcc-ln-wasm32 %s\n", XTC_VERSION);
                return 0;
                }
            else if ([a isEqualToString:@"-q"])
                {
                quiet = YES;
                }
            else if ([a isEqualToString:@"--emit-lib"])
                {
                emitLib = YES;
                }
            else if ([a isEqualToString:@"--iface"] && i + 1 < argc)
                {
                ifacePath = @(argv[++i]);
                }
            else if ([a isEqualToString:@"--loader"] && i + 1 < argc)
                {
                // The support tree's wasm32/runtime/loader.js.in, the one the
                // shipped driver reads too.
                loaderPath = @(argv[++i]);
                }
            else if ([a isEqualToString:@"--dep"] && i + 1 < argc)
                {
                NSString* d = @(argv[++i]);
                if (![deps containsObject:d])
                    [deps addObject:d];
                }
            else if (!inPath)
                {
                inPath = a;
                }
            else if (!outBase)
                {
                outBase = a;
                }
            else
                {
                fprintf(stderr, "xcc-ln-wasm32: unexpected argument '%s'\n", argv[i]);
                return 1;
                }
            }
        if (!inPath || !outBase)
            {
            fprintf(stderr, "Usage: xcc-ln-wasm32 <input.wat> <output-base> [-q] "
                            "[--emit-lib] [--iface <json>] [--dep <name>]...\n");
            return 1;
            }
        NSString* wat = [NSString stringWithContentsOfFile:inPath
                                                  encoding:NSUTF8StringEncoding
                                                     error:NULL];
        if (!wat)
            {
            fprintf(stderr, "xcc-ln-wasm32: cannot read '%s'\n", inPath.UTF8String);
            return 1;
            }
        NSError* err = nil;
        NSData* module = [XTWasmWriter wasmModuleFromWat:wat error:&err];
        if (!module)
            {
            fprintf(stderr, "xcc-ln-wasm32: error: %s\n",
                    err ? err.localizedDescription.UTF8String : "(no detail)");
            return 1;
            }

        // `-o prog` → prog.wasm + prog.js; `-o prog.wasm` keeps the base.
        NSString* base = [outBase.pathExtension isEqualToString:@"wasm"]
                             ? outBase.stringByDeletingPathExtension
                             : outBase;
        NSString* wasmPath = [base stringByAppendingPathExtension:@"wasm"];

        if (emitLib)
            {
            // ── Library build (W2). ──────────────────────────────────────
            // 1. Embed the interface JSON as a `xtc.iface` CUSTOM section —
            //    the same role the ELF `.xtc.iface` section plays, so
            //    `#import <X>` reads the types from the binary itself.
            NSMutableData* libModule = [module mutableCopy];
            NSString* ifaceJson = ifacePath
                                      ? [NSString stringWithContentsOfFile:ifacePath
                                                                  encoding:NSUTF8StringEncoding
                                                                     error:NULL]
                                      : nil;
            if (ifaceJson.length)
                {
                NSData* name = [@"xtc.iface" dataUsingEncoding:NSUTF8StringEncoding];
                NSData* json = [ifaceJson dataUsingEncoding:NSUTF8StringEncoding];
                NSMutableData* payload = [NSMutableData data];
                uint8_t nl = (uint8_t)name.length;
                [payload appendBytes:&nl length:1]; // name len < 128: 1-byte LEB
                [payload appendData:name];
                [payload appendData:json];
                uint8_t zero = 0;
                [libModule appendBytes:&zero length:1]; // section id 0 (custom)
                uint64_t v = payload.length;            // section size, LEB128
                do
                    {
                    uint8_t b = v & 0x7F;
                    v >>= 7;
                    if (v)
                        b |= 0x80;
                    [libModule appendBytes:&b length:1];
                    } while (v);
                [libModule appendData:payload];
                }
            if (![libModule writeToFile:wasmPath atomically:YES])
                {
                fprintf(stderr, "xcc-ln-wasm32: cannot write '%s'\n", wasmPath.UTF8String);
                return 1;
                }
            // 2. The placement sidecar: the backend put the two numbers on
            //    the `;; xtc-lib data=<N> table=<M>` marker line.
            uint64_t dataSize = 0, tableSize = 0;
            for (NSString* ln in [wat componentsSeparatedByString:@"\n"])
                {
                NSString* tr = [ln stringByTrimmingCharactersInSet:
                                       [NSCharacterSet whitespaceCharacterSet]];
                if (![tr hasPrefix:@";; xtc-lib "])
                    continue;
                NSScanner* sc = [NSScanner scannerWithString:tr];
                [sc scanUpToString:@"data=" intoString:NULL];
                [sc scanString:@"data=" intoString:NULL];
                long long d = 0, t = 0; // scanLongLong: — GNUstep's
                                        // NSScanner has no
                                        // scanUnsignedLongLong:
                [sc scanLongLong:&d];
                [sc scanUpToString:@"table=" intoString:NULL];
                [sc scanString:@"table=" intoString:NULL];
                [sc scanLongLong:&t];
                dataSize = d;
                tableSize = t;
                break;
                }
            // 3. The libraries this one imports, by bare name: the loader
            //    loads them too, and relocates each before its importers.
            NSMutableArray<NSString*>* quotedDeps = [NSMutableArray array];
            for (NSString* d in deps)
                [quotedDeps addObject:[NSString stringWithFormat:@"\"%@\"", d]];
            NSString* jsonPath = [base stringByAppendingPathExtension:@"json"];
            NSString* sidecar = [NSString stringWithFormat:
                                              @"{\"dataSize\": %llu, \"tableSize\": %llu, \"deps\": [%@]}\n",
                                              (unsigned long long)dataSize, (unsigned long long)tableSize,
                                              [quotedDeps componentsJoinedByString:@", "]];
            if (![sidecar writeToFile:jsonPath
                           atomically:YES
                             encoding:NSUTF8StringEncoding
                                error:NULL])
                {
                fprintf(stderr, "xcc-ln-wasm32: cannot write '%s'\n", jsonPath.UTF8String);
                return 1;
                }
            if (!quiet)
                fprintf(stderr, "xcc-ln-wasm32: %s (%lu bytes, library) + %s\n",
                        wasmPath.UTF8String, (unsigned long)libModule.length,
                        jsonPath.UTF8String);
            return 0;
            }

        NSString* jsPath = [base stringByAppendingPathExtension:@"js"];
        if (![module writeToFile:wasmPath atomically:YES])
            {
            fprintf(stderr, "xcc-ln-wasm32: cannot write '%s'\n", wasmPath.UTF8String);
            return 1;
            }
        // Without --loader: the template beside this binary, in the source
        // tree (bin/<plat>/ → support/) or an install (bin/ → lib/xc/).
        if (!loaderPath)
            {
            NSString* bin = [@(argv[0]) stringByDeletingLastPathComponent];
            for (NSString* rel in @[ @"../../support", @"../lib/xc", @"../xc", @"xc" ])
                {
                NSString* c = [[bin stringByAppendingPathComponent:rel]
                    stringByAppendingPathComponent:@"wasm32/runtime/loader.js.in"];
                if ([[NSFileManager defaultManager] fileExistsAtPath:c])
                    {
                    loaderPath = c;
                    break;
                    }
                }
            }
        NSString* js = loaderJS(base.lastPathComponent, deps, loaderPath);
        if (!js)
            {
            fprintf(stderr, "xcc-ln-wasm32: cannot read the loader template (--loader %s)\n",
                    loaderPath ? loaderPath.UTF8String : "not given");
            return 1;
            }
        if (![js writeToFile:jsPath
                  atomically:YES
                    encoding:NSUTF8StringEncoding
                       error:NULL])
            {
            fprintf(stderr, "xcc-ln-wasm32: cannot write '%s'\n", jsPath.UTF8String);
            return 1;
            }
        NSString* htmlPath = [base stringByAppendingPathExtension:@"html"];
        BOOL wroteHTML = NO;
        if (![[NSFileManager defaultManager] fileExistsAtPath:htmlPath])
            {
            wroteHTML = [starterHTML(base.lastPathComponent)
                writeToFile:htmlPath
                 atomically:YES
                   encoding:NSUTF8StringEncoding
                      error:NULL];
            }
        if (!quiet)
            fprintf(stderr, "xcc-ln-wasm32: %s (%lu bytes) + %s%s\n",
                    wasmPath.UTF8String, (unsigned long)module.length,
                    jsPath.UTF8String, wroteHTML ? " + starter .html" : "");
        return 0;
        }
    }
