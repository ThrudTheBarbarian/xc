// XTCorpusSweep.m — legacy fixture corpus baseline sweep.
//
// Walks tests/fixtures/*.xc, runs each through the full new-IR
// pipeline targeting the arm64 backend, classifies the outcome,
// aggregates by category and by fixture-name-prefix, and writes
// doc/new-ir-progress.md.
//
// Pass = the pipeline completes and the resulting binary exits
// with code 0 within the per-fixture timeout. There's no oracle
// for stdout — the legacy corpus doesn't carry .expected.out
// files (the previous IR's runners byte-compared .asm output, which
// is incompatible with cross-backend behavioural checks).
//
// Each fixture's outcome lands in one of:
//   pass           — clean pipeline + clean exit-0
//   parse          — lex/parse rejected the source
//   sema           — semantic analyser emitted errors
//   lower          — XTIRLowering failed (often "unsupported X")
//   verify         — XTIRVerifier rejected the lowered module
//   codegen        — XTArm64Backend returned nil (shouldn't normally)
//   assemble_link  — clang -arch arm64 failed
//   runtime        — binary exited non-zero
//   timeout        — binary exceeded the per-fixture deadline
//   no_functions   — fixture has no function with a body
//
// Per-fixture build artefacts (asm, stub, binary, captured stdout
// and stderr, failure log) land in build/corpus/<name>/ for
// post-mortem triage.
#import <Foundation/Foundation.h>
#include <sys/stat.h>
#import "XTArm64HostTools.h"
#import "XTMachOToElfArm64.h"

// The built-binary directory is the HOST's, not always the Mac's: bin/osx on
// macOS, bin/linux on Linux. The Makefile already computes it (BIN_DIR) and
// passes it in as XC_BIN_DIR; the fallback keeps a standalone compile working.
// Hardcoding ./bin/osx here is what made every fixture fail rc=-1 on the Linux
// CI box — the process simply could not be spawned.
#ifndef XC_BIN_DIR
#define XC_BIN_DIR "bin/osx"
#endif
#define XCBIN(tool) (@"./" XC_BIN_DIR "/" tool)
#include <unistd.h>          // getpid() — Apple's Foundation drags this in
                             // transitively, GNUstep's does not, so on Linux
                             // the implicit declaration is a hard error.
#import <signal.h>
#import "XTPreprocessor.h"
#import "XTLexer.h"
#import "XTParser.h"
#import "XTSemanticAnalyzer.h"
#import "XTDesignableSynthesis.h"
#import "XTDiagnosticEngine.h"
#import "XTTypeTable.h"
#import "XTDeclNodes.h"
#import "XTIR.h"
#import "XTIRRuntimeEmitter.h"
#import "XTArm64Backend.h"
#import "XT6502Backend.h"
#import "XT6502AsmPeephole.h"
#import "XTIROptPipeline.h"
#import "XTIROptTargetProfile.h"
#import "XTMemoryModel.h"
#import "XTLinkerScriptParser.h"
#import "XTPointerType.h"
#import "XTStructType.h"

static NSString *const kFixtureDir = @"tests/fixtures";
// NOT const: a SHARDED run gives each shard its own build root. The
// per-fixture dirs under it never collide (they are named by fixture), but
// libxt.o / libxt.a / libxt.err are built once INTO this directory and every
// shard would race to write them. Set in main() from XTC_CORPUS_SHARD_I.
static NSString *kBuildDir = @"build/corpus";

// xt banked memory model (task #60), loaded from the canonical
// layout so the bank windows live in ONE place. The corpus harness
// (xt6502-harness.asm) implements the matching real xt map:
// entry $2400, screen $4000-$5FFF, code-bank window $6000-$9FFF via the
// code selector ($D5C0), data-bank window $A000-$CFFF via the data
// selector ($D5C1, banked heap), software stack $0500-$07FF, and the
// generated unbanked code+data block at $D800-$FFF9 (mainRegionRanges,
// guarded by `.code_regions`). The $A000-$CFFF data window is reserved
// for data and is NEVER code, so it is NOT part of mainRegionRanges —
// the codegen must fit in ~10 KB unbanked ($D800-$FFF9), spilling into
// code banks when needed (phase-060).
//
// The ZP var pool is overridden to dodge the harness's $90-$95 print/heap
// scratch.
static XTMemoryModel *xt6502CorpusModel(void) {
    NSError *err = nil;
    XTMemoryModel *m = [XTLinkerScriptParser
        parseFile:@"support/xt6502/layouts/xt.lnk" error:&err];
    if (!m) {
        fprintf(stderr, "xtc_corpus_sweep: cannot load xt.lnk: %s\n",
                err.localizedDescription.UTF8String);
        return nil;
    }
    // xt.lnk is now the single source of truth: main = $D800-$FFF9 (the
    // $A000-$CFFF data window is never code) and vars = $A0-$AF/$C0-$FF
    // (with $90-$9F reserved for the ARC release path's dispatch-surviving
    // scratch, which the harness below uses). No overrides needed — the
    // subprocess path (xtcg-6502 loading xt.lnk) and this in-process model
    // now agree byte-for-byte.
    return m;
}
static NSString *const kReportPath = @"doc/new-ir-progress.md";
static NSString *const kDivergencePath = @"doc/backend-divergence.md";

#pragma mark - Abandon-reason tally

// Standardised "why did this abandon/get rejected" tally, written
// fresh each full sweep (rm + re-run = clean current picture). Three
// layers: lowering soft-fails are arch-NEUTRAL (a function abandons
// identically on both backends, before the split); backend codegen
// rejections are PER-ARCH. Counts let us read off the top blockers
// by frequency to prioritise the next task.
//
//   doc/abandon-reasons.lower.txt   — lowering soft-fails (shared)
//   doc/abandon-reasons.xt6502.txt  — xt6502 codegen rejections
//   doc/abandon-reasons.arm64.txt   — arm64 codegen rejections
static NSCountedSet<NSString *> *gLowerReasons;
static NSCountedSet<NSString *> *gXtReasons;
static NSCountedSet<NSString *> *gArmReasons;
static NSCountedSet<NSString *> *gArm9Reasons;
// category → one representative "<fixture>: <raw message>" example.
static NSMutableDictionary<NSString *, NSString *> *gLowerExamples;
static NSMutableDictionary<NSString *, NSString *> *gXtExamples;
static NSMutableDictionary<NSString *, NSString *> *gArmExamples;
static NSMutableDictionary<NSString *, NSString *> *gArm9Examples;

// Collapse a raw diagnostic message into a stable category by
// stripping the variable parts: quoted spans ('foo' / "foo") become
// '' / "", and digit runs become #. So `class 'Stdio' has no ivar
// 'canPrint'` and `class 'Foo' has no ivar 'bar'` both fold to
// `class '' has no ivar ''`.
static NSString *normalizeReason(NSString *msg) {
    if ([msg hasPrefix:@"ABANDON|"]) msg = [msg substringFromIndex:8];
    NSMutableString *m = [msg mutableCopy];
    void (^sub)(NSString *) = ^(NSString *pat) {
        NSRegularExpression *re =
            [NSRegularExpression regularExpressionWithPattern:pat options:0 error:NULL];
        // Replacement template references the literal quote chars so the
        // collapsed form keeps the shape (e.g. `''`).
        NSString *tmpl = [pat hasPrefix:@"'"] ? @"''"
                       : [pat hasPrefix:@"\""] ? @"\"\""
                       : @"#";
        [re replaceMatchesInString:m options:0
                             range:NSMakeRange(0, m.length) withTemplate:tmpl];
    };
    sub(@"'[^']*'");
    sub(@"\"[^\"]*\"");
    sub(@"[0-9]+");
    return [m stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static void tallyReason(NSCountedSet *counts,
                        NSMutableDictionary *examples,
                        NSString *rawMsg, NSString *fixture) {
    NSString *cat = normalizeReason(rawMsg);
    if (cat.length == 0) return;
    [counts addObject:cat];
    if (!examples[cat]) {
        NSString *clean = [rawMsg hasPrefix:@"ABANDON|"]
            ? [rawMsg substringFromIndex:8] : rawMsg;
        examples[cat] = [NSString stringWithFormat:@"%@: %@", fixture, clean];
    }
}

// Write one tally file, sorted by descending count. Format per line:
//   <count>\t<category>\t<example fixture: raw message>
static void writeReasonFile(NSString *path, NSString *header,
                            NSCountedSet *counts,
                            NSMutableDictionary *examples) {
    NSArray *cats = [counts.allObjects sortedArrayUsingComparator:
        ^NSComparisonResult(NSString *a, NSString *b) {
            NSUInteger ca = [counts countForObject:a], cb = [counts countForObject:b];
            if (ca != cb) return ca < cb ? NSOrderedDescending : NSOrderedAscending;
            return [a compare:b];
        }];
    NSMutableString *out = [NSMutableString stringWithFormat:@"# %@\n", header];
    [out appendString:@"# Rewritten each full `make corpus`. count\\tcategory\\texample\n\n"];
    for (NSString *cat in cats) {
        [out appendFormat:@"%5lu\t%@\t%@\n",
         (unsigned long)[counts countForObject:cat], cat, examples[cat] ?: @""];
    }
    [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}
static const NSTimeInterval kPerFixtureTimeout = 10.0;

typedef NS_ENUM(NSInteger, XTCorpusOutcome) {
    XTCorpusPass = 0,
    XTCorpusFailPreproc,
    XTCorpusFailParse,
    XTCorpusFailSema,
    XTCorpusFailLower,
    XTCorpusFailVerify,
    XTCorpusFailCodegen,
    XTCorpusFailAssembleLink,
    XTCorpusFailRuntime,
    XTCorpusFailTimeout,
    XTCorpusFailNoFunctions,
    // NOT a pass and NOT a failure: the backend was never executed (its host
    // was unreachable). Kept distinct so an unrun backend can never be tallied
    // as covered — a sweep reporting green for something nothing ran would be
    // worse than one that didn't try.
    XTCorpusNotRun,
};

static NSString *outcomeName(XTCorpusOutcome o) {
    switch (o) {
        case XTCorpusPass:              return @"pass";
        case XTCorpusFailPreproc:       return @"preproc";
        case XTCorpusFailParse:         return @"parse";
        case XTCorpusFailSema:          return @"sema";
        case XTCorpusFailLower:         return @"lower";
        case XTCorpusFailVerify:        return @"verify";
        case XTCorpusFailCodegen:       return @"codegen";
        case XTCorpusFailAssembleLink:  return @"assemble_link";
        case XTCorpusFailRuntime:       return @"runtime";
        case XTCorpusFailTimeout:       return @"timeout";
        case XTCorpusFailNoFunctions:   return @"no_functions";
        case XTCorpusNotRun:            return @"NOT RUN";
    }
    return @"?";
}

@interface XTCorpusResult : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *prefix;

// Top-level outcome. After dual-backend wiring this is XTCorpusPass
// iff BOTH backends pass; otherwise the worst of the two (a
// shared-frontend failure like sema/lower/verify propagates to
// both backends and lands here once).
@property (nonatomic) XTCorpusOutcome outcome;
@property (nonatomic, copy) NSString *message;

// Per-backend outcomes. Both filled in for fixtures that reach the
// backend stage; left as XTCorpusPass when the shared-frontend
// stage failed (the per-backend stages never ran). The report's
// divergence table uses these to surface arm-isms — fixtures
// where one backend passes and the other doesn't.
@property (nonatomic) XTCorpusOutcome arm64Outcome;
@property (nonatomic, copy) NSString *arm64Message;
@property (nonatomic) XTCorpusOutcome xt6502Outcome;
@property (nonatomic, copy) NSString *xt6502Message;
@property (nonatomic) XTCorpusOutcome m68kOutcome;
@property (nonatomic, copy) NSString *m68kMessage;
@property (nonatomic) XTCorpusOutcome arm9Outcome;
@property (nonatomic, copy) NSString *arm9Message;
@property (nonatomic) XTCorpusOutcome x86Outcome;
@property (nonatomic, copy) NSString *x86Message;
// Whether the fixture APPLIES to each backend (i.e. is NOT excluded via
// //xtc-na / target=). The expected-basis report counts pass/applicable.
@property (nonatomic) BOOL arm64Applicable;
@property (nonatomic) BOOL xt6502Applicable;
@property (nonatomic) BOOL m68kApplicable;
@property (nonatomic) BOOL arm9Applicable;
@property (nonatomic) BOOL x86Applicable;

// Per-fixture `target=` scope (an XTCorpusTarget; stored as NSInteger
// because the enum is declared further down). 0 = both, 1 = arm64-only,
// 2 = xt6502-only. The divergence report and the only-one-backend
// tallies use this so an arch-pinned fixture (gr.8 graphics, inline
// 6502 asm) isn't counted as a cross-backend divergence — the other
// backend was never expected to work.
@property (nonatomic) NSInteger target;

// Subprocess pipeline outcome (Stage 11a). The in-process arms above
// run XTIRLowering → backend directly inside this binary; the
// subprocess arm spawns the production `xtc -fnew-ir` command (which
// internally fans out to xtc-fe + xtcg-6502 + in-process xta) so the
// regression net actually exercises the same code path users hit.
// xtPassesViaSubprocess = YES means the fixture also passes via the
// production subprocess path; NO means a round-trip / xtcg-6502 /
// xta gap that needs investigation. Empty xt6502SubprocessMessage
// when YES; the diagnostic on failure otherwise.
@property (nonatomic) BOOL subprocessRan;
@property (nonatomic) BOOL xt6502SubprocessPasses;
@property (nonatomic, copy) NSString *xt6502SubprocessMessage;

// YES when tests/fixtures/<name>.expected.out exists and the
// captured stdout was diffed against it. Used by the report
// renderer to call out "X / N oracled" so the pass count is
// honest about which fixtures had their output checked.
@property (nonatomic) BOOL oracled;
@end
@implementation XTCorpusResult
@end

#pragma mark - Helpers

static NSString *readFile(NSString *path) {
    return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
}

// xts surfaces a 6502 program's own exit code (main's return value) as its
// process status, so a clean run may exit non-zero. A genuine crash — illegal
// opcode or an instruction-limit blow-out — is what signals a runtime failure,
// and xts flags it on stderr. Returns YES if the captured stderr shows the run
// was aborted rather than merely exiting non-zero.
static BOOL xtsAborted(NSString *stderrPath) {
    NSString *err = readFile(stderrPath);
    if (!err) return NO;
    return [err containsString:@"illegal opcode"] ||
           [err containsString:@"instruction limit"];
}

static void ensureDir(NSString *path) {
    [[NSFileManager defaultManager] createDirectoryAtPath:path
                              withIntermediateDirectories:YES attributes:nil error:NULL];
}

// ---- child-process reaping on sweep death -------------------------------
// A killed or interrupted sweep (session reset, Ctrl-C, `kill`, terminal
// hang-up) must not leave its in-flight children running. qemu-system-arm is
// the dangerous case: a fixture whose guest never returns keeps qemu — and
// its ~1 GB — alive forever, reparented to PID 1 with nothing left to reap it.
// (The per-fixture timeout path below already cleans up while the sweep is
// alive; this covers the sweep itself dying mid-fixture.) We record every live
// child PID and SIGKILL them from a signal handler / atexit hook, so the
// sweep's death takes its children with it.
#define kMaxLiveChildren 64
static volatile sig_atomic_t gLiveChildren[kMaxLiveChildren];

static void trackChildPid(pid_t pid) {
    for (int i = 0; i < kMaxLiveChildren; i++) {
        if (gLiveChildren[i] == 0) { gLiveChildren[i] = pid; return; }
    }
}
static void untrackChildPid(pid_t pid) {
    for (int i = 0; i < kMaxLiveChildren; i++) {
        if (gLiveChildren[i] == pid) { gLiveChildren[i] = 0; return; }
    }
}
// async-signal-safe: only touches the flat pid table and calls kill().
static void killTrackedChildren(void) {
    for (int i = 0; i < kMaxLiveChildren; i++) {
        pid_t pid = (pid_t)gLiveChildren[i];
        if (pid > 0) { kill(pid, SIGKILL); gLiveChildren[i] = 0; }
    }
}
static void reapAndReraise(int sig) {
    killTrackedChildren();
    signal(sig, SIG_DFL);   // restore default and re-raise so the sweep
    raise(sig);             // still dies with the expected status
}
static void installChildReaper(void) {
    atexit(killTrackedChildren);
    signal(SIGINT,  reapAndReraise);
    signal(SIGTERM, reapAndReraise);
    signal(SIGHUP,  reapAndReraise);
}

// Run a subprocess with a wall-clock deadline. SIGTERM after the
// deadline; SIGKILL another second later if it didn't exit. Returns
// YES on a clean wait, populates *timedOut if the deadline tripped.
static BOOL runSubprocess(NSString *launchPath,
                          NSArray<NSString *> *args,
                          NSString *stdoutPath,
                          NSString *stderrPath,
                          NSTimeInterval timeoutSeconds,
                          int *exitCodeOut,
                          BOOL *timedOutOut)
{
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = launchPath;
    task.arguments = args;
    NSFileManager *fm = [NSFileManager defaultManager];
    if (stdoutPath) {
        [fm createFileAtPath:stdoutPath contents:[NSData data] attributes:nil];
        task.standardOutput = [NSFileHandle fileHandleForWritingAtPath:stdoutPath];
    } else {
        task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    }
    if (stderrPath) {
        [fm createFileAtPath:stderrPath contents:[NSData data] attributes:nil];
        task.standardError = [NSFileHandle fileHandleForWritingAtPath:stderrPath];
    } else {
        task.standardError = [NSFileHandle fileHandleWithNullDevice];
    }
    @try {
        [task launch];
    } @catch (NSException *e) {
        if (exitCodeOut) *exitCodeOut = -1;
        if (timedOutOut) *timedOutOut = NO;
        return NO;
    }
    pid_t childPid = task.processIdentifier;
    trackChildPid(childPid);
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeoutSeconds];
    while (task.isRunning) {
        if ([[NSDate date] compare:deadline] != NSOrderedAscending) {
            [task terminate];   // SIGTERM
            [NSThread sleepForTimeInterval:0.5];
            if (task.isRunning) {
                kill(task.processIdentifier, SIGKILL);
            }
            [task waitUntilExit];
            untrackChildPid(childPid);
            if (exitCodeOut) *exitCodeOut = task.terminationStatus;
            if (timedOutOut) *timedOutOut = YES;
            return YES;
        }
        [NSThread sleepForTimeInterval:0.02];
    }
    untrackChildPid(childPid);
    if (exitCodeOut) *exitCodeOut = task.terminationStatus;
    if (timedOutOut) *timedOutOut = NO;
    return YES;
}

// As runSubprocess, but feeds `stdinStr` to the child's stdin (then closes it).
// Used to drive the XTOS loader shell under qemu: a small `runhost <so>\nexit`
// script. Running qemu DIRECTLY (not via a shell pipe) means the timeout path
// terminates qemu itself, never orphaning it.
static BOOL runSubprocessWithStdin(NSString *launchPath,
                                   NSArray<NSString *> *args,
                                   NSString *stdinStr,
                                   NSString *stdoutPath,
                                   NSString *stderrPath,
                                   NSTimeInterval timeoutSeconds,
                                   int *exitCodeOut,
                                   BOOL *timedOutOut)
{
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = launchPath;
    task.arguments = args;
    NSFileManager *fm = [NSFileManager defaultManager];
    if (stdoutPath) {
        [fm createFileAtPath:stdoutPath contents:[NSData data] attributes:nil];
        task.standardOutput = [NSFileHandle fileHandleForWritingAtPath:stdoutPath];
    } else {
        task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    }
    if (stderrPath) {
        [fm createFileAtPath:stderrPath contents:[NSData data] attributes:nil];
        task.standardError = [NSFileHandle fileHandleForWritingAtPath:stderrPath];
    } else {
        task.standardError = [NSFileHandle fileHandleWithNullDevice];
    }
    NSPipe *inPipe = [NSPipe pipe];
    task.standardInput = inPipe;
    @try {
        [task launch];
    } @catch (NSException *e) {
        if (exitCodeOut) *exitCodeOut = -1;
        if (timedOutOut) *timedOutOut = NO;
        return NO;
    }
    @try {
        [inPipe.fileHandleForWriting writeData:
            [stdinStr dataUsingEncoding:NSUTF8StringEncoding]];
        [inPipe.fileHandleForWriting closeFile];
    } @catch (NSException *e) { /* child may have exited; ignore */ }

    pid_t childPid = task.processIdentifier;
    trackChildPid(childPid);
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeoutSeconds];
    while (task.isRunning) {
        if ([[NSDate date] compare:deadline] != NSOrderedAscending) {
            [task terminate];
            [NSThread sleepForTimeInterval:0.5];
            if (task.isRunning) kill(task.processIdentifier, SIGKILL);
            [task waitUntilExit];
            untrackChildPid(childPid);
            if (exitCodeOut) *exitCodeOut = task.terminationStatus;
            if (timedOutOut) *timedOutOut = YES;
            return YES;
        }
        [NSThread sleepForTimeInterval:0.02];
    }
    untrackChildPid(childPid);
    if (exitCodeOut) *exitCodeOut = task.terminationStatus;
    if (timedOutOut) *timedOutOut = NO;
    return YES;
}

// Word-boundary regex replace: any occurrence of `_<oldName>` that
// sits at word boundaries becomes `_<newName>`. Lets us renames
// xtc-side symbols (`_main` → `_xt_main`) without touching nested
// labels (`L_main__bb_entry` stays put because the inner `_main`
// has word-chars on both sides).
static NSString *renameSymbol(NSString *asmText, NSString *oldName, NSString *newName) {
    NSString *pattern = [NSString stringWithFormat:@"\\b_%@\\b", oldName];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                       options:0 error:NULL];
    if (!re) return asmText;
    NSString *replacement = [NSString stringWithFormat:@"_%@", newName];
    return [re stringByReplacingMatchesInString:asmText options:0
                                          range:NSMakeRange(0, asmText.length)
                                   withTemplate:replacement];
}

#pragma mark - Per-fixture pipeline

// Pick the function to call from the C stub. Prefers `main`; falls
// back to the first function with a body. Returns nil if none.
static XTIRFunction *pickEntryFunction(XTIRModule *mod) {
    XTIRFunction *first = nil;
    for (XTIRFunction *fn in mod.functions) {
        // The "has a body" test for a stub-call candidate.
        if (fn.entryBlock == nil) continue;
        BOOL hasBody = fn.entryBlock.terminator != nil
                    || fn.entryBlock.instructions.count > 0
                    || fn.entryBlock.phiNodes.count > 0;
        if (!hasBody) continue;
        if ([fn.name isEqualToString:@"main"]) return fn;
        if (!first) first = fn;
    }
    return first;
}

// Read a file relative to the executable's working directory.
// `relPath` is relative to the SUPPORT ROOT, matching XTIRRuntimeEmitter — the
// tree is support/ here and lib/xc in an install, and the two readers must not
// disagree about what a path means.
static NSString *readHarnessTemplate(NSString *rel) {
    NSString *relPath = [@"support" stringByAppendingPathComponent:rel];
    NSString *s = [NSString stringWithContentsOfFile:relPath
                                             encoding:NSUTF8StringEncoding
                                                error:NULL];
    if (!s) {
        // Some test runners cwd to the parent. Try a sibling path.
        s = [NSString stringWithContentsOfFile:[@"../" stringByAppendingString:relPath]
                                      encoding:NSUTF8StringEncoding
                                         error:NULL];
    }
    return s ?: @"";
}

// Emit unbanked thunks for a set of banked-runtime entry points (task #121).
// Each `_<name>` thunk trampolines (via the harness's _xcall) into the banked
// bare-label `<name>`, selecting bank `<bankSymbol>` — a `__bank_<id>` value
// the assembler publishes for the matching `.bank <id>` region. The codegen
// already calls the runtime as `_<name>`, landing here directly; bare-name
// inline-asm calls (`JSR fpAdd`) are retargeted onto these thunks by xta's
// cross-bank rewrite. Keeping the staging in ONE shared thunk per entry (vs
// inlined at each call site) keeps every call a 3-byte JSR, so banked user
// functions don't blow their 16 KB budget. Sound because the arithmetic
// runtime uses the $B0-$BF ZP ABI (the A-clobber + bank switch are invisible).
static void appendBankedRuntimeThunks(NSMutableString *out,
                                      NSArray<NSString *> *entryNames,
                                      NSString *bankSymbol)
{
    for (NSString *n in entryNames) {
        [out appendFormat:
            @"_%@:\n"
            @"    LDA #<%@\n    STA _xcall_vec\n"
            @"    LDA #>%@\n    STA _xcall_vec+1\n"
            @"    LDA #%@\n    STA _xc_bank\n"
            @"    JMP _xcall\n", n, n, n, bankSymbol];
    }
}

// Build a per-fixture 6502-asm wrapper. Delegates the universal wrapping
// (harness template + allocator stubs + heap + banked runtime thunks) to
// the shared XTIRRuntimeEmitter; the corpus's only addition on top is the
// `main` → `xt_main` symbol rename done by the caller before calling.
static NSString *buildXt6502Stub(XTIRModule *mod,
                                  NSString *generatedAsm)
{
    return [XTIRRuntimeEmitter wrapXt6502Asm:generatedAsm
                                   forModule:mod
                                 memoryModel:xt6502CorpusModel()
                                 harnessPath:@"xt6502/runtime/xt6502-harness.asm"];
}

// (Original inlined implementation retained below — guarded out so the
// helper class is the single source of truth. Delete in a follow-up
// once the helper has matured.)
#if 0
static NSString *buildXt6502Stub_OLD(XTIRModule *mod,
                                  NSString *generatedAsm)
{
    NSMutableString *out = [NSMutableString string];
    [XTIRRuntimeEmitter setSupportRoot:@"support"];
    NSString *harness = readHarnessTemplate(@"xt6502/runtime/xt6502-harness.asm");
    [out appendString:harness];
    [out appendString:@"\n"];

    // Per-class __xtc_new_<T> stubs. Allocate (size + 1) bytes
    // (the +1 is the refcount byte); set refcount = 1; return the
    // pointer past the refcount in A:X:Y (3-byte banked pointer).
    // The size comes from the class's instance-layout entry — for
    // the 3-byte-pointer layout the lowering emits, that's the
    // layout.size field.
    // Per-class / per-primitive `new` allocators route through the REAL
    // free-list allocator (heap.asm `_heap_alloc16`, embedded below), so the
    // corpus exercises the actual -falloc=heap runtime + reference counting
    // rather than a bump fiction. `_heap_alloc16` takes the PAYLOAD size in
    // A=lo/X=hi, reserves the 4-byte block header (size + 16-bit refcount,
    // initialised to 1), and returns the payload pointer in A=lo/X=hi.
    //   - primitive `new T[N]`: the lowering passes the element count as the
    //     single arg; on the custom xt CPU, the push16 JSR return address
    //     lands at SP+1/SP+2 (lo/hi), so the arg sits at SP+3 (lo) / SP+4 (hi).
    //   - class `new Foo()`: no count arg — pass a conservative fixed 64.
    static NSDictionary<NSString *, NSNumber *> *primElemWidths;
    static dispatch_once_t onceXt;
    dispatch_once(&onceXt, ^{
        primElemWidths = @{
            @"bool":    @1,
            @"i8":      @1,
            @"u8":      @1,
            @"i16":     @2,
            @"u16":     @2,
            @"i32":     @4,
            @"u32":     @4,
            @"pointer": @3,    // 3-byte uniform pointers (task #92)
            @"string":  @3,    // String references are pointers too
            @"float":   @5,
            @"double":  @8,
        };
    });
    for (XTIRSymbol *sym in mod.symbols) {
        if (sym.kind != XTIRSymbolKindRuntimeHelper) continue;
        if (![sym.name hasPrefix:@"_xtc_new_"]) continue;
        NSString *suffix = [sym.name substringFromIndex:@"_xtc_new_".length];
        NSNumber *widthNum = primElemWidths[suffix];
        if (widthNum) {
            NSUInteger w = widthNum.unsignedIntegerValue;
            NSUInteger shift = 0;
            NSUInteger tmp = w;
            while ((tmp & 1) == 0 && tmp > 1) { shift++; tmp >>= 1; }
            BOOL isPowerOfTwo = (tmp == 1);
            
            NSMutableString *stub = [NSMutableString string];
            [stub appendFormat:@"_%@:\n", sym.name];
            if (isPowerOfTwo && shift == 0) {
                // Width=1: pass element count directly to _heap_alloc16.
                // Custom CPU stack (push-then-decrement, so SP points one
                // BELOW the last-pushed byte): SP+0 is the empty next-free
                // slot, SP+1/+2 = the JSR return address (lo/hi), and the
                // single push16 argument sits at SP+3 (lo) / SP+4 (hi).
                [stub appendString:@"    LDA +3,SP\n"
                                    @"    LDX +4,SP\n"
                                    @"    JMP _heap_alloc16\n"];
            } else if (isPowerOfTwo) {
                // Width is a power of two > 1 (2, 4, 8). Read element
                // count from SP+3 (lo) / SP+4 (hi), multiply by width,
                // then pass to _heap_alloc16 (which expects A=lo, X=hi).
                // The ASL/ROL 16-bit multiply produces A=hi, X=lo, so
                // swap via _tmp before the tail-call.
                [stub appendString:@"    LDA +3,SP\n"
                                    @"    TAX\n"
                                    @"    LDA +4,SP\n"];
                for (NSUInteger b = 0; b < shift; b++) {
                    [stub appendString:@"    ASL A\n"
                                        @"    PHA\n"
                                        @"    TXA\n"
                                        @"    ROL A\n"
                                        @"    TAX\n"
                                        @"    PLA\n"];
                }
                [stub appendString:@"    STX _tmp\n"
                                    @"    ADC #$00\n"
                                    @"    TAX\n"
                                    @"    LDA _tmp\n"
                                    @"    JMP _heap_alloc16\n"];
            } else {
                // Non-power-of-two width (pointer/string = 3, float = 5):
                // size = count * width, computed as `width` repeated 16-bit
                // additions of count. The element count sits at +3/+4,SP
                // (lo/hi) — push-then-decrement leaves SP+0 as the empty
                // next-free slot, SP+1/+2 as the JSR return address, so the
                // single push16 argument lands at SP+3/+4 — and the running
                // total lives in the 16-bit scratch `_tmp`. (A previous
                // version both read the count one slot too low at +2/+3 and
                // PHA'd the accumulator, so a return-address byte was summed
                // into the size → a pointer-like garbage size that overflowed
                // every heap bank → OOM, and `new pointer[N]` returned null —
                // breaking foundation_map_*/set_* pointer-bucket allocations.)
                NSUInteger w = widthNum.unsignedIntegerValue;
                [stub appendString:@"    LDA +3,SP\n"      // total = count
                                    @"    STA _tmp\n"
                                    @"    LDA +4,SP\n"
                                    @"    STA _tmp+1\n"];
                for (NSUInteger r = 1; r < w; r++) {        // += count, (w-1)x
                    [stub appendString:@"    CLC\n"
                                        @"    LDA _tmp\n"
                                        @"    ADC +3,SP\n"
                                        @"    STA _tmp\n"
                                        @"    LDA _tmp+1\n"
                                        @"    ADC +4,SP\n"
                                        @"    STA _tmp+1\n"];
                }
                [stub appendString:@"    LDA _tmp\n"        // A=lo, X=hi
                                    @"    LDX _tmp+1\n"
                                    @"    JMP _heap_alloc16\n"];
            }
            [out appendString:stub];
            continue;
        }
        // Class instance allocator: check if this class has a dealloc method.
        NSString *className = suffix;
        NSString *deallocName = [NSString stringWithFormat:@"%@$dealloc", className];
        BOOL hasDealloc = NO;
        for (XTIRFunction *fn in mod.functions) {
            if ([fn.name isEqualToString:deallocName]) {
                hasDealloc = YES;
                break;
            }
        }
        // Class instance allocator. Every class instance carries a
        // 3-byte dealloc descriptor [bank, addr-lo, addr-hi] at a FIXED
        // payload offset (xtc_desc_off = 60, defined in the harness) that
        // __xtc_release reads at refcount 0. It can NOT live at object+0:
        // the IR lowering stores a dispatch class's vtable pointer there
        // (private:docs/bugs/004 layer-2 #1). 60 is past every released class's
        // ivars but inside the conservative 64-byte payload, so the same
        // slot works for dispatch (vtable at +0) and plain classes alike.
        //   • has-dealloc → [__dbank_<Class>$dealloc, <addr, >addr]. The
        //     bank is the REAL code bank the backend packed the destructor
        //     into (private:docs/bugs/003: the old hard-coded #$01 was wrong once
        //     a `$dealloc` landed in bank 2+).
        //   • no-dealloc → all-zero, so __xtc_release skips dispatch and
        //     just frees. The slot must be zeroed explicitly because the
        //     free-list heap does NOT clear reused payloads.
        if (hasDealloc) {
            [out appendFormat:
                @"_%@:\n"
                @"    LDX #$00\n"
                @"    LDA #$40\n"              // 64-byte payload (conservative)
                @"    JSR _heap_alloc16\n"
                @"    STA $90\n"               // save ptr lo
                @"    STX $91\n"               // save ptr hi
                @"    STY $92\n"               // save ptr bank
                @"    STY __bank_data_reg\n"   // select object's data bank
                @"    LDA $90\n"
                @"    STA $98\n"
                @"    LDA $91\n"
                @"    STA $99\n"               // ZP[2] = object pointer
                @"    LDY #xtc_desc_off\n"     // descriptor at object+60
                @"    LDA #__dbank_%@$dealloc\n"  // REAL destructor code bank
                @"    STA ($98),Y\n"
                @"    INY\n"
                @"    LDA #<_%@$dealloc\n"     // addr-lo
                @"    STA ($98),Y\n"
                @"    INY\n"
                @"    LDA #>_%@$dealloc\n"     // addr-hi
                @"    STA ($98),Y\n"
                // Array cookie: elemSize at +56, count at +58 — the lowering
                // passes (count, elemSize) as args (count @ SP+3/4, elemSize
                // @ SP+5/6; SP is unchanged after the balanced _heap_alloc16).
                // __xtc_release reads these to run dealloc once per element.
                @"    LDY #56\n"
                @"    LDA +5,SP\n"             // elemSize lo
                @"    STA ($98),Y\n"
                @"    INY\n"
                @"    LDA +6,SP\n"             // elemSize hi
                @"    STA ($98),Y\n"
                @"    INY\n"                   // Y = 58
                @"    LDA +3,SP\n"             // count lo
                @"    STA ($98),Y\n"
                @"    INY\n"
                @"    LDA +4,SP\n"             // count hi
                @"    STA ($98),Y\n"
                @"    LDA #$00\n"
                @"    STA __bank_data_reg\n"   // restore data bank
                @"    LDA $90\n"
                @"    LDX $91\n"
                @"    LDY $92\n"
                @"    RTS\n",
                sym.name, className, className, className];
        } else {
            [out appendFormat:
                @"_%@:\n"
                @"    LDX #$00\n"
                @"    LDA #$40\n"             // 64-byte payload (conservative)
                @"    JSR _heap_alloc16\n"
                @"    STA $90\n"
                @"    STX $91\n"
                @"    STY $92\n"
                @"    STY __bank_data_reg\n"  // select object's data bank
                @"    LDA $90\n"
                @"    STA $98\n"
                @"    LDA $91\n"
                @"    STA $99\n"
                @"    LDA #$00\n"             // null dealloc descriptor
                @"    LDY #xtc_desc_off\n"    // at object+60
                @"    STA ($98),Y\n"
                @"    INY\n"
                @"    STA ($98),Y\n"
                @"    INY\n"
                @"    STA ($98),Y\n"
                @"    STA __bank_data_reg\n"  // restore data bank (A=0)
                @"    LDA $90\n"
                @"    LDX $91\n"
                @"    LDY $92\n"
                @"    RTS\n",
                sym.name];
        }
    }
    // B1: the single generic class allocator (mirrors the driver's
    // XTIRRuntimeEmitter). `new T` → _xtc_alloc(count, stride, deallocPtr); the
    // per-class loop above now fires only for primitive arrays. Args (little-
    // endian on the hw stack): count @+3,+4; stride @+5,+6; deallocPtr (3-byte
    // banked fn ptr) lo@+7, hi@+8, bank@+9. Descriptor at obj+60 = [bank,lo,hi]
    // (the order __xtc_release reads); null deallocPtr → all-zero → no-dtor.
    {
        BOOL usesAlloc = NO;
        for (XTIRSymbol *sym in mod.symbols) {
            if (sym.kind == XTIRSymbolKindRuntimeHelper
                && [sym.name isEqualToString:@"_xtc_alloc"]) { usesAlloc = YES; break; }
        }
        if (usesAlloc) {
            [out appendString:
                @"__xtc_alloc:\n"
                @"    LDX #$00\n    LDA #$40\n    JSR _heap_alloc16\n"
                @"    STA $90\n    STX $91\n    STY $92\n    STY __bank_data_reg\n"
                @"    LDA $90\n    STA $98\n    LDA $91\n    STA $99\n"
                @"    LDY #xtc_desc_off\n"
                @"    LDA +9,SP\n    STA ($98),Y\n"            // descriptor bank
                @"    INY\n    LDA +7,SP\n    STA ($98),Y\n"   // descriptor lo
                @"    INY\n    LDA +8,SP\n    STA ($98),Y\n"   // descriptor hi
                @"    LDY #56\n"
                @"    LDA +5,SP\n    STA ($98),Y\n"            // cookie elemSize lo
                @"    INY\n    LDA +6,SP\n    STA ($98),Y\n"   // cookie elemSize hi
                @"    INY\n    LDA +3,SP\n    STA ($98),Y\n"   // cookie count lo
                @"    INY\n    LDA +4,SP\n    STA ($98),Y\n"   // cookie count hi
                @"    LDA #$00\n    STA __bank_data_reg\n"
                @"    LDA $90\n    LDX $91\n    LDY $92\n    RTS\n"];
        }
    }
    // bank(BANK_TYPE, idx) builtin → _xtc_bank(u8 type, u8 idx) returns a
    // 3-byte (lo, hi, bank) pointer addressing byte 0 of the requested
    // window in bank `idx`. Window bases mirror the new-xt memory map:
    //   BANK_DATA (0) → $A000-$CFFF (12 KB data window, $83/$84-selected)
    //   BANK_CODE (1) → $6000-$9FFF (16 KB code window, $82-selected)
    //   BANK_C    (2) → unsupported on new-xt (region C is gone) → null
    // Args land at SP+3 (type) / SP+4 (idx) under the push-then-decrement
    // ABI. Return: A=lo, X=hi, Y=bank (the standard 3-byte ptr return).
    for (XTIRSymbol *sym in mod.symbols) {
        if (sym.kind != XTIRSymbolKindRuntimeHelper) continue;
        if (![sym.name isEqualToString:@"_xtc_bank"]) continue;
        [out appendString:
            @"__xtc_bank:\n"
            @"    LDA +4,SP\n"           // idx → Y (bank byte of the return ptr)
            @"    TAY\n"
            @"    LDA +3,SP\n"           // type
            @"    BEQ __xb_data\n"       // 0 → BANK_DATA
            @"    CMP #$01\n"
            @"    BEQ __xb_code\n"       // 1 → BANK_CODE
            @"    LDA #$00\n"            // BANK_C / invalid → null ptr
            @"    LDX #$00\n"
            @"    LDY #$00\n"
            @"    RTS\n"
            @"__xb_data:\n"
            @"    LDA #$00\n"            // $A000 low
            @"    LDX #$A0\n"            // $A000 high
            @"    RTS\n"
            @"__xb_code:\n"
            @"    LDA #$00\n"            // $6000 low
            @"    LDX #$60\n"            // $6000 high
            @"    RTS\n"];
        break;
    }

    // The real free-list heap + ARC runtime, with the driver's template
    // placeholders expanded for the corpus's BANKED config (data pages
    // via $83/$84, $A000-$D000 window). Replaces the previous bump stubs
    // so the corpus tests the shipping allocator. Lands in the unbanked
    // runtime region ($2400-$3FFF) — reachable by a plain JSR from any
    // bank — BEFORE the generated code's own .org. heap.asm/retain.asm
    // carry no .org.
    [out appendString:@"\n; ── banked free-list heap config (corpus) ──\n"];
    [out appendString:
        @"heap_bank_first = $01\n"
        @"heap_bank_last  = $10\n"       // 16 pages × 12 KB = 192 KB (Heap.size's
                                          // _heap_total_free is now 24-bit, so the
                                          // >64 KB free count reports correctly)
        @"regC_heap_bank_first = $00\n"
        @"regC_heap_bank_last  = $00\n"
        @"heap_low  = $A000\n"
        @"heap_end  = $D000\n"
        @"regC_heap_low = $0000\n"
        @"regC_heap_end = $0000\n"
        // Compile-time heap capacity for Heap.totalSize(): (last-first+1)
        // banks * (heap_end-heap_low). 16 * $3000 = $30000 (192 KB). The
        // shipping driver emits these; the corpus must too or totalSize()
        // reads an undefined symbol (→ 0). Low 16 bits + bytes 2/3 (the
        // total exceeds 64 KB).
        @"heap_total_bytes    = $0000\n"   // 16 * $3000 = $30000 = 192 KB
        @"heap_total_bytes_b2 = $03\n"
        @"heap_total_bytes_b3 = $00\n"];
    [out appendString:
        @"_tmp: .byte $00, $00\n"];    // scratch for _xtc_new_<T> non-pow2 multiply
    // bank-xt.asm provides _heap_select_bank, _heap_save_caller_bank,
    // _heap_restore_caller_bank for the $83/$84 data window. Its local
    // labels are prefixed with _hbn_ to avoid collisions.
    NSString *bankXt = readHarnessTemplate(@"support/xt6502/asm/heap/bank-xt.asm");
    [out appendString:bankXt];
    [out appendString:@"\n"];
    NSString *heapSrc = readHarnessTemplate(@"support/xt6502/asm/heap/heap.asm");
    heapSrc = [heapSrc stringByReplacingOccurrencesOfString:@"{{zp.hp}}" withString:@"$96"];
    heapSrc = [heapSrc stringByReplacingOccurrencesOfString:@"{{zp.tmp}}" withString:@"$98"];
    NSString *retainSrc = readHarnessTemplate(@"support/xt6502/asm/heap/retain.asm");
    retainSrc = [retainSrc stringByReplacingOccurrencesOfString:@"{{zp.tmp}}" withString:@"$98"];
    retainSrc = [retainSrc stringByReplacingOccurrencesOfString:@"{{weak.zeroAllHook}}"
                                                     withString:@"; (corpus: no weak side-table)"];
    // xt's data bank is the 8-bit $83 selector captured in Y; there
    // is no bank-hi byte with 3-byte uniform pointers. The old expansion
    // also wrote `LDA $89 / STA _obj_bank_hi`, but `_obj_bank_hi` is not
    // declared anywhere → it resolved to $0000, so every decref clobbered
    // ZP $0000 (private:docs/bugs/003 adjacent note). Drop that regC-era leftover.
    retainSrc = [retainSrc stringByReplacingOccurrencesOfString:@"{{heap.objBankStash}}"
                                                     withString:@"STY _obj_bank"];
    [out appendString:@"\n"];
    [out appendString:heapSrc];
    [out appendString:@"\n"];
    [out appendString:retainSrc];

    // ── Float / double arithmetic runtime: BANKED (task #121) ───────
    // The float pack is always linked; the float-extras (trig/sqrt/abs/
    // mod) and the double pack are pulled in only when referenced. All of
    // them are BANKED via the assembler's `.bank` directive: their bare-
    // label bodies live in a named bank (`fpRuntime`) appended after the
    // generated code, and xta auto-rewrites every cross-bank `JSR`/`JMP`
    // to them — whether `_<name>` (codegen) or bare `<name>` (library /
    // fixture inline asm) — into the _xcall trampoline. Internal cross-
    // refs use bare names and stay intra-bank. This frees ~10 KB of
    // unbanked budget. The integer mul/div/mod pack stays unbanked in the
    // harness template (small; same $B0-$B7 clobber-safe ABI).
    //
    // Scans match both the codegen's `_<name>` calls and bare-name
    // references so the conditional packs link when only inline asm uses
    // them.
    BOOL (^uses)(NSString *) = ^BOOL(NSString *rt) {
        return [generatedAsm containsString:
                    [NSString stringWithFormat:@"JSR _%@", rt]]
            || [generatedAsm containsString:
                    [NSString stringWithFormat:@"JSR %@", rt]];
    };

    NSMutableSet<NSString *> *neededFloatExtras = [NSMutableSet set];
    if (uses(@"fpSin") || uses(@"fpCos") || uses(@"fpTan") || uses(@"fpAtan"))
        [neededFloatExtras addObject:@"fpTrig"];
    if (uses(@"fpSqrt")) [neededFloatExtras addObject:@"fpSqrt"];
    if (uses(@"fpAbs"))  [neededFloatExtras addObject:@"fpAbs"];
    if (uses(@"fpMod"))  [neededFloatExtras addObject:@"fpMod"];

    BOOL needDouble =
        [generatedAsm containsString:@"JSR _dp"] ||
        [generatedAsm containsString:@"JSR dp"] ||
        uses(@"u32ToDp") || uses(@"i32ToDp") || uses(@"u16ToDp") ||
        uses(@"i16ToDp") || uses(@"u8ToDp")  || uses(@"i8ToDp")  ||
        uses(@"dpToFp")  || uses(@"fpToDp")  || uses(@"asc2dp");

    // Float entries (= .include basenames). The codegen calls them via
    // `_<name>` (→ the thunks below); bare-name inline-asm calls get
    // retargeted onto the thunks by xta's cross-bank rewrite.
    NSArray<NSString *> *floatNames = @[
        @"u32ToFp", @"i32ToFp", @"i16ToFp", @"i8ToFp", @"u16ToFp", @"u8ToFp",
        @"fpToI32", @"fpAdd", @"fpSub", @"fpMul", @"fpDiv", @"fpCmp", @"fp2Asc",
        @"asc2fp"];   // ASCII→float (only ever reached via inline asm `JSR asc2fp`)
    // The float pack is linked only when actually used — directly, via the
    // extras, or via double (whose converters call the float converters).
    // Skipping it for float-free fixtures avoids perturbing their unbanked
    // layout with a dead bank + thunks (which exposed a latent layout-
    // sensitive bug in foundation_map_basic).
    BOOL needFloat = needDouble || neededFloatExtras.count > 0;
    if (!needFloat)
        for (NSString *n in floatNames)
            if (uses(n)) { needFloat = YES; break; }
    NSArray<NSString *> *extrasNames = @[
        @"fpSin", @"fpCos", @"fpTan", @"fpAtan", @"fpSqrt", @"fpAbs", @"fpMod"];
    NSArray<NSString *> *doubleNames = @[
        @"dpAdd", @"dpSub", @"dpMul", @"dpDiv", @"dpCmp", @"dp2Asc",
        @"dpToFp", @"fpToDp", @"i8ToDp", @"i16ToDp", @"i32ToDp",
        @"u8ToDp", @"u16ToDp", @"u32ToDp", @"dpSqrt", @"dpMod", @"asc2dp"];

    // The float-extras entries that are actually linked (for thunking).
    NSMutableArray<NSString *> *extrasLinked = [NSMutableArray array];
    if ([neededFloatExtras containsObject:@"fpTrig"])
        [extrasLinked addObjectsFromArray:@[@"fpSin", @"fpCos", @"fpTan", @"fpAtan"]];
    if ([neededFloatExtras containsObject:@"fpSqrt"]) [extrasLinked addObject:@"fpSqrt"];
    if ([neededFloatExtras containsObject:@"fpAbs"])  [extrasLinked addObject:@"fpAbs"];
    if ([neededFloatExtras containsObject:@"fpMod"])  [extrasLinked addObject:@"fpMod"];
    (void)extrasNames;

    // ── Unbanked thunks (before the generated code). float + extras live
    //    in bank `fpRuntime`; double in `dpRuntime`. Only emitted for the
    //    packs actually linked, so a float-free fixture's layout is
    //    unchanged. ──
    if (needFloat || needDouble) {
        [out appendString:@"\n; ── Banked-runtime thunks (task #121) ──\n"];
        if (needFloat) {
            appendBankedRuntimeThunks(out, floatNames, @"__bank_fpRuntime");
            appendBankedRuntimeThunks(out, extrasLinked, @"__bank_fpRuntime");
        }
        if (needDouble)
            appendBankedRuntimeThunks(out, doubleNames, @"__bank_dpRuntime");
    }

    // ── The generated code (user banks → 1..N). ──
    [out appendString:@"\n"];
    [out appendString:generatedAsm];

    // ── The banked runtime bodies (bare labels). Emitted LAST so the
    //    assembler allocates each `.bank` after the user banks. Double
    //    gets its OWN bank: float + extras + double together exceed the
    //    16 KB window (gfx8 fixtures hit ~17.4 KB); the double→float
    //    converter calls cross the fpRuntime/dpRuntime boundary and the
    //    cross-bank rewrite routes them through the thunks. ──
    if (needFloat || needDouble)
        [out appendString:@"\n; ── Banked float/double runtime (task #121) ──\n"];
    if (needFloat) {
        [out appendString:@".bank fpRuntime\n"];
        for (NSString *name in floatNames)
            [out appendFormat:@".include \"support/xt6502/asm/float/%@.asm\"\n", name];
        if ([neededFloatExtras containsObject:@"fpTrig"]) {
            [out appendString:@".include \"support/xt6502/asm/float/fpTrig.asm\"\n"];
            // fpTrig.asm calls _fp_reduce_to_pi for range reduction; pull in
            // fpTrigReduce.asm or it resolves to $0000. (fpTrigTab.asm is a
            // SEPARATE table-based trig implementation that also defines
            // fpSin/etc. — including it here would duplicate those labels.)
            [out appendString:@".include \"support/xt6502/asm/float/fpTrigReduce.asm\"\n"];
        }
        if ([neededFloatExtras containsObject:@"fpSqrt"])
            [out appendString:@".include \"support/xt6502/asm/float/fpSqrt.asm\"\n"];
        if ([neededFloatExtras containsObject:@"fpAbs"])
            [out appendString:@".include \"support/xt6502/asm/float/fpAbs.asm\"\n"];
        if ([neededFloatExtras containsObject:@"fpMod"])
            [out appendString:@".include \"support/xt6502/asm/float/fpMod.asm\"\n"];
    }
    if (needDouble) {
        [out appendString:@".bank dpRuntime\n"];
        for (NSString *name in doubleNames)
            [out appendFormat:@".include \"support/xt6502/asm/double/%@.asm\"\n", name];
    }
    return out;
}
#endif  // close the `#if 0` that hid the original buildXt6502Stub body

// Build a C stub that calls `fn` with default-zero args and exits 0.
// The xtc function is renamed to xt_<name> in the emitted .s when its
// name is `main` (to avoid colliding with C's own main). The stub
// also provides trivial bodies for the runtime-helper symbols the
// backend's class-flavoured opcodes call into — `_xtc_new_<T>`,
// `_xtc_dealloc`, `_xtc_weak_*`. Without these, every class fixture
// would die at link time on the assemble step.
static NSString *buildStubCForFunction(XTIRFunction *fn,
                                        NSString *calleeNameAfterRename,
                                        XTIRModule *mod)
{
    NSMutableString *s = [NSMutableString string];
    [s appendString:@"#include <stdint.h>\n"];
    [s appendString:@"#include <stdlib.h>\n"];
    [s appendString:@"#include <stdio.h>\n"];
    // Native console primitive: the arm64 Stdio emits each formatted
    // byte through `_putc` rather than poking screen RAM, so arm64 output
    // lands on real stdout (the corpus oracle) instead of the
    // `_atari_mem` sandbox.
    [s appendString:@"void _putc(uint8_t c) { putchar((int)c); }\n"];
    // Float / double formatters for the arm64 Stdio %f / %lf / print
    // path. Match the Atari fp2Asc / dp2Asc shape: fixed 6 decimals for
    // float, 10 for double (printf %.*f rounds the same way as the 6502
    // routine for the exactly-representable values the fixtures use).
    // Gated on the module referencing them, like the libm wrappers.
    BOOL usesFloatPrint = NO;
    for (XTIRSymbol *sym in mod.symbols) {
        if ([sym.name isEqualToString:@"_xtc_pf"]
            || [sym.name isEqualToString:@"_xtc_pd"]
            || [sym.name isEqualToString:@"_xtc_pfp"]
            || [sym.name isEqualToString:@"_xtc_pdp"]) { usesFloatPrint = YES; break; }
    }
    // `.length` of a runtime-sized heap array (private:docs/bugs/045): the count from
    // THIS stub's header, which is
    //
    //     [stride:8][count:8][dealloc:8][refcount:4] payload…
    //      p+0       p+8      p+16       p+24         p+28
    //
    // so the count is at payload-20. It read payload-18 until 2026-09-01,
    // which was right while the refcount was TWO bytes and wrong from the
    // moment 046 widened it to four — the offset lives here and the layout is
    // written twenty lines below, and only the layout was updated. Reading two
    // bytes into the middle of the count gave zero, so `buf.length` answered 0
    // and `heap_length_runtime` failed while the same program compiled by the
    // driver was correct. private:docs/bugs/027 is the same shape: a contract spelled
    // in two places drifts.
    for (XTIRSymbol *sym in mod.symbols) {
        if ([sym.name isEqualToString:@"_xtc_count"]) {
            [s appendString:
                @"uint16_t _xtc_count(void*o){return (uint16_t)*(unsigned long*)((uint8_t*)o-20);}\n"];
            break;
        }
    }
    if (usesFloatPrint) {
        // `_xtc_pfp` / `_xtc_pdp` honour `%.Np` precision (N = 0 reverts
        // to the historic 6dp / 10dp default so a plain `%f` print stays
        // byte-identical to the Atari fp2Asc width).
        [s appendString:
            @"void _xtc_pf(float f){ printf(\"%.6f\", (double)f); }\n"
            @"void _xtc_pd(double d){ printf(\"%.10f\", d); }\n"
            // Truncate (no rounding) so the output byte-matches xt6502
            // Stdio's print(float, precision) which walks fp2Asc's
            // ATASCII buffer and stops after N digits past the dot.
            // Format with N+1 precision then drop the trailing digit —
            // standard at non-boundary values; rounding-boundary cases
            // (3.9999 -> 4.000) can still diverge by one ULP, the cost
            // of using `%.Nf` for cross-arch matching.
            @"#include <string.h>\n"
            @"static void _xtc_truncf(double v, uint8_t p) {\n"
            @"    char buf[64];\n"
            @"    snprintf(buf, sizeof(buf), \"%.*f\", (int)(p + 1), v);\n"
            @"    size_t L = strlen(buf);\n"
            @"    if (L > 0) buf[L - 1] = 0;\n"
            @"    fputs(buf, stdout);\n"
            @"}\n"
            @"void _xtc_pfp(float f, uint8_t p){\n"
            @"    if (p == 0) { printf(\"%.6f\", (double)f); }\n"
            @"    else        { _xtc_truncf((double)f, p); }\n"
            @"}\n"
            @"void _xtc_pdp(double d, uint8_t p){\n"
            @"    if (p == 0) { printf(\"%.10f\", d); }\n"
            @"    else        { _xtc_truncf(d, p); }\n"
            @"}\n"];
    }
    // libm wrappers for the arm64 Math.xc port. It declares `_xm_*`
    // externs (sqrt/sin/cos/tan/atan/ln/exp/pow, float + double) and
    // routes its transcendentals through them; the host C library
    // provides the actual implementations. Emitted only when the module
    // references one (a non-math fixture's stub stays lean). Mirrors the
    // `_putc` host-primitive pattern.
    BOOL usesMath = NO;
    for (XTIRSymbol *sym in mod.symbols) {
        if ([sym.name hasPrefix:@"_xm_"]) { usesMath = YES; break; }
    }
    if (usesMath) {
        [s appendString:
            @"#include <math.h>\n"
            @"float  _xm_sqrtf(float x){return sqrtf(x);}\n"
            @"double _xm_sqrt(double x){return sqrt(x);}\n"
            @"float  _xm_sinf(float x){return sinf(x);}\n"
            @"double _xm_sin(double x){return sin(x);}\n"
            @"float  _xm_cosf(float x){return cosf(x);}\n"
            @"double _xm_cos(double x){return cos(x);}\n"
            @"float  _xm_tanf(float x){return tanf(x);}\n"
            @"double _xm_tan(double x){return tan(x);}\n"
            @"float  _xm_atanf(float x){return atanf(x);}\n"
            @"double _xm_atan(double x){return atan(x);}\n"
            @"float  _xm_lnf(float x){return logf(x);}\n"
            @"double _xm_ln(double x){return log(x);}\n"
            @"float  _xm_expf(float x){return expf(x);}\n"
            @"double _xm_exp(double x){return exp(x);}\n"
            @"float  _xm_powf(float a,float b){return powf(a,b);}\n"
            @"double _xm_pow(double a,double b){return pow(a,b);}\n"];
    }
    // The arm64 Time class's host clock primitives (_xt_clk_reset /
    // _xt_clk_ticks / _xt_clk_delay) now live in libxt.a (linked by the
    // arm64 pipeline), not inline here — so they're a real, distributable
    // runtime rather than per-fixture generated fiction.
    // Runtime-helper stubs derived from the module's symbol table.
    // Each `_xtc_new_<T>` returns a pointer past a single refcount
    // byte; `_xtc_dealloc` frees the original allocation. Weak-slot
    // helpers degrade to plain pointer slots (no zeroing-on-dealloc
    // — close enough for the corpus's "does it link and run"
    // measurement).
    // Primitive (non-class) element types: `new pointer[N]` /
    // `new u8[N]` route through `_xtc_new_<type>` with the element
    // count passed as the first arg (x0). The allocation must scale
    // with N — a fixed size silently overflows once the element
    // stride is correct (an arm64 `pointer@` cell is 8 bytes, so a
    // 32-slot Map buffer needs 256 bytes, blowing past a fixed 256
    // and corrupting the adjacent heap chunk). Class instance
    // allocators (`new Foo()`) pass no count, so they keep the fixed
    // conservative size.
    static NSSet<NSString *> *primElemTypes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        primElemTypes = [NSSet setWithArray:@[@"pointer", @"bool",
            @"i8", @"u8", @"i16", @"u16", @"i32", @"u32",
            @"float", @"double", @"string"]];
    });
    // Object header layout (uniform across every allocation):
    //   [dealloc fn-ptr : 8 bytes][refcount : 1 byte][object data…]
    //                                                 ^ returned pointer
    // The refcount stays at obj-1 (matches the backend's `[obj,#-1]`
    // read/write); the per-class dealloc fn-ptr sits at obj-9. On free,
    // _xtc_dealloc reads it and — when non-null — calls the user
    // destructor so `dealloc(){…}` side effects fire and the ARC
    // refcount fixtures observe them, mirroring the 6502 harness's
    // obj+0 dealloc descriptor. Primitive-element allocations and
    // classes with no dealloc store a null fn-ptr.
    for (XTIRSymbol *sym in mod.symbols) {
        if (sym.kind != XTIRSymbolKindRuntimeHelper) continue;
        if (![sym.name hasPrefix:@"_xtc_new_"]) continue;
        NSString *suffix = [sym.name substringFromIndex:@"_xtc_new_".length];
        if ([primElemTypes containsObject:suffix]) {
            // Count-aware: bytes = n * 8 (8 = the widest element this
            // language has — an arm64 pointer / double). Floored at
            // 256 so a scalar `new T` (no count, garbage x0) and the
            // header are always covered; capped so a stray garbage
            // count can't request an absurd allocation. Null dealloc.
            // Uniform 28-byte header [stride:8][count:8][fnptr:8][rc:4];
            // data = base+28, rc at obj-4 (the backend's 32-bit refcount slot).
            // Null dealloc fn-ptr → _xtc_dealloc's per-element loop is
            // skipped (primitive buffers have no destructor).
            [s appendFormat:@"void *%@(unsigned long n) {\n"
                             @"    unsigned long b = n * 8;\n"
                             @"    if (b < 256) b = 256;\n"
                             @"    if (b > (16UL << 20)) b = 256;\n"
                             @"    uint8_t *p = (uint8_t *)malloc(b + 28);\n"
                             @"    *(unsigned long *)(p + 0) = 8;\n"   // stride (unused)
                             @"    *(unsigned long *)(p + 8) = n;\n"   // count
                             @"    *(void (**)(void *))(p + 16) = 0;\n"  // null dealloc
                             @"    *(uint32_t *)(p + 24) = 1;\n"                       // refcount
                             @"    return p + 28;\n"
                             @"}\n", sym.name];
            continue;
        }
        // Class instance allocator. If the class declares a dealloc
        // method, stash its address so _xtc_dealloc dispatches it on
        // free (same has-dealloc test as the 6502 stub).
        NSString *deallocName = [NSString stringWithFormat:@"%@$dealloc", suffix];
        BOOL hasDealloc = NO;
        for (XTIRFunction *fn in mod.functions) {
            if ([fn.name isEqualToString:deallocName]) { hasDealloc = YES; break; }
        }
        // Class allocator: (count, elemSize) from the lowering. Stores both
        // in the header so `delete` of an array-of-class iterates dealloc
        // per element. Allocation = max(count*elemSize, 256) — singles keep
        // the conservative floor (no size change); arrays get sized.
        if (hasDealloc) {
            // `$` is a legal identifier char under Clang's default
            // -fdollars-in-identifiers, so `Foo$dealloc` resolves to
            // the Mach-O symbol `_Foo$dealloc` the backend emits.
            [s appendFormat:@"extern void %@(void *);\n"
                             @"void *%@(unsigned long count, unsigned long stride) {\n"
                             @"    if (count < 1) count = 1;\n"
                             @"    unsigned long b = count * stride;\n"
                             @"    if (b < 256) b = 256;\n"
                             @"    if (b > (16UL << 20)) b = 256;\n"
                             @"    uint8_t *p = (uint8_t *)malloc(b + 28);\n"
                             @"    *(unsigned long *)(p + 0) = stride;\n"
                             @"    *(unsigned long *)(p + 8) = count;\n"
                             @"    *(void (**)(void *))(p + 16) = (void (*)(void *))&%@;\n"
                             @"    *(uint32_t *)(p + 24) = 1;\n"
                             @"    return p + 28;\n"
                             @"}\n", deallocName, sym.name, deallocName];
        } else {
            [s appendFormat:@"void *%@(unsigned long count, unsigned long stride) {\n"
                             @"    if (count < 1) count = 1;\n"
                             @"    unsigned long b = count * stride;\n"
                             @"    if (b < 256) b = 256;\n"
                             @"    if (b > (16UL << 20)) b = 256;\n"
                             @"    uint8_t *p = (uint8_t *)malloc(b + 28);\n"
                             @"    *(unsigned long *)(p + 0) = stride;\n"
                             @"    *(unsigned long *)(p + 8) = count;\n"
                             @"    *(void (**)(void *))(p + 16) = 0;\n"
                             @"    *(uint32_t *)(p + 24) = 1;\n"
                             @"    return p + 28;\n"
                             @"}\n", sym.name];
        }
    }
    // B1: the single generic class allocator (mirrors main.m's arm64StubSource).
    // `new T` -> _xtc_alloc(count, stride, deallocPtr); one allocator for every
    // class, the dealloc fn-ptr passed by the caller. Same 28-byte header.
    {
        BOOL usesAlloc = NO;
        for (XTIRSymbol *sym in mod.symbols)
            if (sym.kind == XTIRSymbolKindRuntimeHelper
                && [sym.name isEqualToString:@"_xtc_alloc"]) { usesAlloc = YES; break; }
        if (usesAlloc)
            [s appendString:
                @"void *_xtc_alloc(unsigned long count, unsigned long stride, void (*dealloc)(void *)) {\n"
                @"    if (count < 1) count = 1;\n"
                @"    unsigned long b = count * stride;\n"
                @"    if (b < 256) b = 256;\n"
                @"    if (b > (16UL << 20)) b = 256;\n"
                @"    uint8_t *p = (uint8_t *)malloc(b + 28);\n"
                @"    *(unsigned long *)(p + 0) = stride;\n"
                @"    *(unsigned long *)(p + 8) = count;\n"
                @"    *(void (**)(void *))(p + 16) = dealloc;\n"
                @"    *(uint32_t *)(p + 24) = 1;\n"
                @"    return p + 28;\n"
                @"}\n"];
    }
    // Free path: read the [stride,count,fnptr] cookie; if there's a
    // destructor, run it on EACH element (arr[i] = o + i*stride) before
    // freeing the single block. count=1 for a scalar `new T()` → one call.
    // Weak side-table (real, not the old `*slot = obj` no-op): register
    // records (obj → slot) so _xtc_dealloc can zero every slot pointing at
    // a dying object before freeing it (private:docs/bugs/011 #6). Defined before
    // _xtc_dealloc so the dealloc can call the zero-walk. Always present —
    // for non-weak programs the table stays empty so the walk is a no-op.
    [s appendString:
        @"static struct { void *obj; void **slot; } _xtc_weak_tbl[1024];\n"
        @"void _xtc_weak_register(void **slot, void *obj) {\n"
        @"    for (int i = 0; i < 1024; i++) if (_xtc_weak_tbl[i].slot == slot) { _xtc_weak_tbl[i].obj = 0; _xtc_weak_tbl[i].slot = 0; }\n"
        @"    if (!obj) return;\n"
        @"    for (int i = 0; i < 1024; i++) if (!_xtc_weak_tbl[i].slot) { _xtc_weak_tbl[i].obj = obj; _xtc_weak_tbl[i].slot = slot; return; }\n"
        @"}\n"
        @"void _xtc_weak_unregister(void **slot) {\n"
        @"    for (int i = 0; i < 1024; i++) if (_xtc_weak_tbl[i].slot == slot) { _xtc_weak_tbl[i].obj = 0; _xtc_weak_tbl[i].slot = 0; }\n"
        @"}\n"
        @"void *_xtc_weak_load(void **slot) { return *slot; }\n"
        @"static void _xtc_weak_zero_for(void *obj) {\n"
        @"    if (!obj) return;\n"
        @"    for (int i = 0; i < 1024; i++) if (_xtc_weak_tbl[i].obj == obj) { *_xtc_weak_tbl[i].slot = 0; _xtc_weak_tbl[i].obj = 0; _xtc_weak_tbl[i].slot = 0; }\n"
        @"}\n"
        @"void _xtc_dealloc(void *o) {\n"
        @"    _xtc_weak_zero_for(o);\n"
        @"    uint8_t *base = (uint8_t *)o - 28;\n"
        @"    unsigned long stride = *(unsigned long *)(base + 0);\n"
        @"    unsigned long count  = *(unsigned long *)(base + 8);\n"
        @"    void (*d)(void *) = *(void (**)(void *))(base + 16);\n"
        @"    if (d) for (unsigned long i = 0; i < count; i++) d((uint8_t *)o + i * stride);\n"
        @"    free(base);\n"
        @"}\n"];
    // bank(BANK_TYPE, idx) builtin → _xtc_bank(uint8_t type, uint8_t idx)
    // simulates the xt bank-window concept on arm64 by lazy-allocating a
    // 12 KB chunk per (type, idx) and returning the same pointer on every
    // call with the same key. Two callers' writes round-trip via shared
    // storage — matching what xt6502's $A000-$CFFF window does once $83/$84
    // selects bank `idx`. Only emitted when the module references the
    // helper, so non-banking fixtures stay lean.
    BOOL usesBank = NO;
    for (XTIRSymbol *sym in mod.symbols) {
        if ([sym.name isEqualToString:@"_xtc_bank"]) { usesBank = YES; break; }
    }
    if (usesBank) {
        [s appendString:
            @"#include <string.h>\n"
            @"static void *_xtc_bank_regions[3][256] = {{0}};\n"
            @"void *_xtc_bank(uint8_t type, uint8_t idx) {\n"
            @"    if (type > 1) return 0;   /* BANK_C unsupported on new-xt */\n"
            @"    if (!_xtc_bank_regions[type][idx]) {\n"
            @"        _xtc_bank_regions[type][idx] = calloc(1, 12288);\n"
            @"    }\n"
            @"    return _xtc_bank_regions[type][idx];\n"
            @"}\n"];
    }
    // Declare the callee with zero args — the AAPCS calling convention
    // means whatever the function expects in x0..x7 will get whatever
    // happens to be there at the call. For "does it run" verification
    // this is fine.
    [s appendFormat:@"extern void %@(void);\n", calleeNameAfterRename];
    [s appendFormat:@"int main(void) { %@(); return 0; }\n", calleeNameAfterRename];
    return s;
}

#pragma mark - Per-backend pipelines

// Build the host runtime archive libxt.a once (from support/arm64/runtime/
// libxt.c) and return its path, or nil if the build failed. The arm64
// pipeline links it quietly into every program; static-archive semantics
// mean a program that references none of its symbols pulls nothing in.
static NSString *ensureLibxtArchive(void) {
    static NSString *result = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ensureDir(kBuildDir);
        NSString *src = @"support/arm64/runtime/libxt.c";
        NSString *obj = [kBuildDir stringByAppendingPathComponent:@"libxt.o"];
        NSString *arc = [kBuildDir stringByAppendingPathComponent:@"libxt.a"];
        NSString *errPath = [kBuildDir stringByAppendingPathComponent:@"libxt.err"];
        int rc = 0; BOOL to = NO;
        BOOL c = runSubprocess(@"/usr/bin/env",
            [XTArm64ClangArgv() arrayByAddingObjectsFromArray:
                @[@"-O2", @"-c", src, @"-o", obj]],
            nil, errPath, 30.0, &rc, &to);
        if (!c || rc != 0) return;
        BOOL a = runSubprocess(@"/usr/bin/env",
            @[@"ar", @"rcs", arc, obj], nil, errPath, 30.0, &rc, &to);
        if (!a || rc != 0) return;
        result = arc;
    });
    return result;
}

// Returns the pipeline outcome for the arm64 backend on a
// pre-lowered, pre-verified module. Writes per-fixture artefacts
// (gen.s, stub.c, bin, stdout.txt, stderr.txt) under fixBuildDir.
// `outMessage` is set on failure; the top-level harness composes
// a "arm64: <msg>" / "xt6502: <msg>" if the two backends diverge.
static XTCorpusOutcome runArm64Pipeline(XTIRModule *mod,
                                          XTIRFunction *entry,
                                          NSString *fixBuildDir,
                                          BOOL *outOracled,
                                          NSString **outMessage)
{
    *outMessage = nil;
    *outOracled = NO;

    // Opt pipeline at the -O3 default with the arm64 profile (production level).
    {
        XTIROptPipeline *pipe =
            [XTIROptPipeline standardPipelineAtLevel:3
                                             profile:[XTIRArm64TargetProfile new]];
        NSMutableArray<NSString *> *poErrs = nil;
        if (![pipe runOnModule:mod errors:&poErrs]) {
            *outMessage = [NSString stringWithFormat:@"opt pipeline failed: %@",
                           poErrs.firstObject ?: @"(no detail)"];
            return XTCorpusFailCodegen;
        }
    }

    NSString *asmText = nil;
    @try {
        // On a bionic host the fixture is linked by the NDK and run under
        // qemu, so the backend must emit AAPCS64 and avoid LSE atomics —
        // exactly what the driver forwards for -A android. Without them the
        // failures are silent-ish: garbage printf output (cvariadic_call,
        // exit_flush) and "instruction requires: lse" at assembly time
        // (every threads_* fixture). See XTArm64HostTools.h.
        if (XTArm64UsesBionicAbi()) {
            [XTArm64Backend setAapcs64Abi:YES];
            [XTArm64Backend setLseAtomics:NO];
        }
        asmText = [XTArm64Backend assemblyFromModule:mod];
    } @catch (NSException *e) {
        *outMessage = [NSString stringWithFormat:@"codegen exception: %@", e.reason];
        return XTCorpusFailCodegen;
    }
    if (!asmText) {
        *outMessage = @"backend returned nil";
        return XTCorpusFailCodegen;
    }

    NSString *calleeName = entry.name;
    if ([calleeName isEqualToString:@"main"]) {
        asmText = renameSymbol(asmText, @"main", @"xt_main");
        calleeName = @"xt_main";
    }

    // Mach-O flavoured asm has to become ELF before a cross toolchain will
    // link it — `_sa` vs `sa`, @PAGE/@PAGEOFF vs :lo12:. No-op on macOS, where
    // the host toolchain wants the dialect it was given.
    if (XTArm64NeedsElfDialect()) asmText = XTMachOToElfArm64(asmText);

    NSString *asmPath = [fixBuildDir stringByAppendingPathComponent:@"gen.s"];
    NSString *stubPath = [fixBuildDir stringByAppendingPathComponent:@"stub.c"];
    NSString *binPath = [fixBuildDir stringByAppendingPathComponent:@"bin"];
    NSString *stdoutPath = [fixBuildDir stringByAppendingPathComponent:@"stdout.txt"];
    NSString *stderrPath = [fixBuildDir stringByAppendingPathComponent:@"stderr.txt"];

    [asmText writeToFile:asmPath atomically:YES
                encoding:NSUTF8StringEncoding error:NULL];
    NSString *stubC = buildStubCForFunction(entry, calleeName, mod);
    [stubC writeToFile:stubPath atomically:YES
              encoding:NSUTF8StringEncoding error:NULL];

    int rc = 0;
    BOOL timedOut = NO;
    // Link the host runtime archive (real wall-clock time etc.) after the
    // objects; static-archive semantics keep it quiet for fixtures that
    // reference none of its symbols.
    NSArray<NSString *> *arm64cc = XTArm64ClangArgv();
    if (!arm64cc) {
        *outMessage = @"no arm64 compiler (set $XC_ARM64_CC or $ANDROID_NDK_HOME)";
        return XTCorpusFailAssembleLink;
    }
    NSMutableArray *clangArgs =
        [[arm64cc arrayByAddingObjectsFromArray:@[stubPath, asmPath]] mutableCopy];
    NSString *libxt = ensureLibxtArchive();
    if (libxt) [clangArgs addObject:libxt];
    [clangArgs addObjectsFromArray:@[@"-o", binPath]];
    BOOL spawnOK = runSubprocess(@"/usr/bin/env", clangArgs,
        nil, stderrPath, 30.0, &rc, &timedOut);
    if (!spawnOK || rc != 0) {
        *outMessage = [NSString stringWithFormat:@"clang rc=%d", rc];
        return XTCorpusFailAssembleLink;
    }

    NSArray<NSString *> *arm64pre = XTArm64RunPrefix();
    BOOL execOK = arm64pre
        ? runSubprocess(@"/usr/bin/env", [arm64pre arrayByAddingObject:binPath],
                        stdoutPath, stderrPath, kPerFixtureTimeout, &rc, &timedOut)
        : runSubprocess(binPath, @[], stdoutPath, stderrPath,
                        kPerFixtureTimeout, &rc, &timedOut);
    if (timedOut) {
        *outMessage = [NSString stringWithFormat:@"timed out after %.0fs", kPerFixtureTimeout];
        return XTCorpusFailTimeout;
    }
    if (!execOK || rc != 0) {
        *outMessage = [NSString stringWithFormat:@"binary exited rc=%d", rc];
        return XTCorpusFailRuntime;
    }

    // Oracle diff. Prefer a per-backend `<name>.expected.arm64.out`
    // when present (fixtures whose float-precision or PRNG path
    // genuinely diverges from xt6502, e.g. ahl); fall back to the
    // common `<name>.expected.out` otherwise.
    NSString *name = [fixBuildDir lastPathComponent];
    NSString *archOraclePath = [NSString stringWithFormat:
        @"%@/%@.expected.arm64.out", kFixtureDir, name];
    NSString *expected = [NSString stringWithContentsOfFile:archOraclePath
                                                   encoding:NSUTF8StringEncoding
                                                      error:NULL];
    if (!expected) {
        NSString *oraclePath = [NSString stringWithFormat:
            @"%@/%@.expected.out", kFixtureDir, name];
        expected = [NSString stringWithContentsOfFile:oraclePath
                                             encoding:NSUTF8StringEncoding
                                                error:NULL];
    }
    if (expected) {
        *outOracled = YES;
        NSString *actual = readFile(stdoutPath) ?: @"";
        if (![actual isEqualToString:expected]) {
            NSArray<NSString *> *expLines = [expected componentsSeparatedByString:@"\n"];
            NSArray<NSString *> *actLines = [actual componentsSeparatedByString:@"\n"];
            NSUInteger firstDiff = NSNotFound;
            NSUInteger commonLen = MIN(expLines.count, actLines.count);
            for (NSUInteger i = 0; i < commonLen; i++) {
                if (![expLines[i] isEqualToString:actLines[i]]) {
                    firstDiff = i; break;
                }
            }
            if (firstDiff == NSNotFound) firstDiff = commonLen;
            NSString *expLine = firstDiff < expLines.count
                ? expLines[firstDiff] : @"<end>";
            NSString *actLine = firstDiff < actLines.count
                ? actLines[firstDiff] : @"<end>";
            *outMessage = [NSString stringWithFormat:
                @"oracle mismatch at line %lu: expected '%@' got '%@'",
                (unsigned long)firstDiff + 1, expLine, actLine];
            return XTCorpusFailRuntime;
        }
    }
    return XTCorpusPass;
}

// Returns the pipeline outcome for the xt6502 backend on a
// pre-lowered, pre-verified module. Writes per-fixture artefacts
// (gen.6502.asm, combined.asm, fixture.xex, stdout-6502.txt) under
// fixBuildDir.
// Atari ST/TT (m68k) pipeline: reuse the arm64-lowered module (m68k uses
// 2-byte-pointer IR + independent field remap, like arm64), emit via
// XTM68kBackend (-mhard-float so the emulator's FPU path is exercised),
// assemble in-process to a GEMDOS $601A, run under xst, diff the oracle.
static NSString *corpusLinkCompanion(NSString *rawSource); // defined below
static NSString *stripFunctionPrototypes(NSString *src);   // defined below

// Atari ST/TT (m68k) corpus pipeline — its OWN honest subprocess, like the
// xt6502 subprocess path: compile the fixture with the real driver
// (xtc -A 68030, atarist platform, full opt pipeline), run under xst, diff
// the oracle. -mhard-float because xst models the 68881 FPU. (Was an
// in-process reuse of the arm64-lowered module, which tested a different,
// pre-opt code path than the real compiler.)
static XTCorpusOutcome runM68kPipeline(NSString *xtPath,
                                       NSString *fixBuildDir,
                                       BOOL *outOracled,
                                       NSString **outMessage)
{
    *outMessage = nil;
    *outOracled = NO;
    NSString *prgPath    = [fixBuildDir stringByAppendingPathComponent:@"fixture-m68k.prg"];
    NSString *cgStderr   = [fixBuildDir stringByAppendingPathComponent:@"m68k-compile-stderr.txt"];
    NSString *stdoutPath = [fixBuildDir stringByAppendingPathComponent:@"stdout-m68k.txt"];
    NSString *stderrPath = [fixBuildDir stringByAppendingPathComponent:@"stderr-m68k.txt"];
    NSString *rawSource  = [NSString stringWithContentsOfFile:xtPath
                                                     encoding:NSUTF8StringEncoding error:NULL];

    // `//xtc-flags: m68k-soft-float` builds without the FPU instead, so the
    // soft-float helpers (line-A math HLE) are what runs.
    BOOL softFloat = NO;
    for (NSString *line in [rawSource componentsSeparatedByString:@"\n"]) {
        NSString *t = [line stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];
        if (![t hasPrefix:@"//xtc-flags:"] && ![t hasPrefix:@"// xtc-flags:"]) continue;
        if ([t rangeOfString:@"m68k-soft-float"].location != NSNotFound) softFloat = YES;
    }
    NSMutableArray<NSString *> *xtcArgs = softFloat
        ? [@[@"-A", @"68030", @"-q"] mutableCopy]
        : [@[@"-mhard-float", @"-A", @"68030", @"-q"] mutableCopy];

    // //xtc-link companion: m68k emits a whole-program image (like xt6502),
    // so "link" by compiling the pair as ONE unit — strip the caller's
    // prototypes and append the companion's definitions.
    NSString *compileInput = xtPath;
    NSString *companion = rawSource ? corpusLinkCompanion(rawSource) : nil;
    if (companion) {
        NSString *compPath = [NSString stringWithFormat:@"%@/%@.xc", kFixtureDir, companion];
        NSString *compSrc = [NSString stringWithContentsOfFile:compPath
                                                      encoding:NSUTF8StringEncoding error:NULL];
        if (compSrc) {
            NSString *merged = [NSString stringWithFormat:@"%@\n%@",
                                stripFunctionPrototypes(rawSource), compSrc];
            NSString *mergedPath = [fixBuildDir stringByAppendingPathComponent:@"m68k-merged.xc"];
            if ([merged writeToFile:mergedPath atomically:YES
                           encoding:NSUTF8StringEncoding error:NULL])
                compileInput = mergedPath;
        }
    }
    [xtcArgs addObjectsFromArray:@[compileInput, @"-o", prgPath]];

    int rc = 0; BOOL to = NO;
    BOOL ok = runSubprocess(XCBIN("xcc"), xtcArgs, nil, cgStderr, 60.0, &rc, &to);
    if (!ok || rc != 0 || to) {
        *outMessage = [NSString stringWithFormat:@"xtc -A 68030 rc=%d%s",
                       rc, to ? " timed out" : ""];
        return XTCorpusFailCodegen;
    }

    // rc is main()'s return value (crt0 Pterms with it), not a fault — the
    // oracle (captured stdout) is the verdict.
    // Match the compile target (-A 68030): xst defaults to a 68000 core, which
    // silently ignores 68020+ addressing scales (`(a0,dN.l*4)`), so the CPU must
    // be selected explicitly.
    ok = runSubprocess(XCBIN("xcc-sim-68k"), @[@"--cpu", @"68030", @"-d", prgPath],
        stdoutPath, stderrPath, kPerFixtureTimeout, &rc, &to);
    if (to)  { *outMessage = @"xst timed out"; return XTCorpusFailTimeout; }
    if (!ok) { *outMessage = @"xst spawn failed"; return XTCorpusFailRuntime; }

    NSString *name = [fixBuildDir lastPathComponent];
    NSString *archOracle = [NSString stringWithFormat:@"%@/%@.expected.atarist.out", kFixtureDir, name];
    NSString *expected = [NSString stringWithContentsOfFile:archOracle
                                                   encoding:NSUTF8StringEncoding error:NULL];
    if (!expected) {
        NSString *oraclePath = [NSString stringWithFormat:@"%@/%@.expected.out", kFixtureDir, name];
        expected = [NSString stringWithContentsOfFile:oraclePath
                                             encoding:NSUTF8StringEncoding error:NULL];
    }
    if (expected) {
        *outOracled = YES;
        NSString *actual = readFile(stdoutPath) ?: @"";
        if (![actual isEqualToString:expected]) { *outMessage = @"oracle mismatch"; return XTCorpusFailRuntime; }
    }
    return XTCorpusPass;
}

/****************************************************************************\
|* x86-64 host. The backend targets System V / musl Linux, which this macOS
|* box can build but not run, so fixtures execute over ssh on a Linux host
|* (XTC_X86_HOST, or XTC_LINUX_HOST when that is unset).
|*
|* Reachability is probed ONCE, and the result is NOT allowed to fail quietly:
|* an unreachable host means x86-64 is simply NOT COVERED, and a sweep that
|* silently scored it as passing would be worse than not running it at all —
|* it would report green for a backend nothing executed. So x86HostReachable()
|* prints a loud banner on failure, and every x86 result is marked NotRun.
\****************************************************************************/
static NSString *x86Host(void) {
    const char *env = getenv("XTC_X86_HOST");
    if (env && *env) return [NSString stringWithUTF8String:env];
    const char *fallback = getenv("XTC_LINUX_HOST");
    return (fallback && *fallback) ? [NSString stringWithUTF8String:fallback] : @"";
}

// ...unless this box IS the Linux host. The comment above is written from the
// Mac's point of view, where "build it but not run it" is simply true. On the
// x86-64 CI box the fixture is NATIVE: shipping it over ssh to another machine
// to run it would be a round trip to nowhere, and it makes coverage depend on
// a second machine being up.
//
// `localhost` and `-` both mean "here". The Makefile picks the default per
// host, so a Mac still defaults to a remote host and the box does not.
static BOOL x86RunsLocally(void) {
#if defined(__linux__) && defined(__x86_64__)
    NSString *h = x86Host();
    return h.length == 0 || [h isEqualToString:@"localhost"] || [h isEqualToString:@"-"];
#else
    return NO;
#endif
}

// XTC_X86_SELFHOST=1 routes the x86-64 leg through the in-house assembler and
// ELF writer instead of the /opt/clang cross toolchain. Same fixture selection,
// same directives, same companion merging, same oracles — so the pass count is
// directly comparable with the clang run, which a separate shell harness with
// its own fixture filter is not.
static BOOL x86SelfHost(void) {
    const char *env = getenv("XTC_X86_SELFHOST");
    return env && *env && strcmp(env, "0") != 0;
}

/****************************************************************************\
|* Path of the shared ssh control socket.
|*
|* The x86 leg makes TWO connections per fixture — one scp, one ssh — and at
|* ~350 fixtures that is ~700 full SSH handshakes. Measured on this pair of
|* machines: 170 ms each cold, ~20 ms over a multiplexed socket, so the
|* handshakes alone cost about two minutes of a sweep. One master connection is
|* opened when the host is first probed and every later scp/ssh rides it.
|*
|* If the master dies, ssh falls back to a normal connection — slower, still
|* correct — so this is an optimisation with no new failure mode.
\****************************************************************************/
static NSString *x86ControlPath(void) {
    static NSString *p;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        p = [NSString stringWithFormat:@"/tmp/xtc-corpus-ssh-%d", (int)getpid()];
    });
    return p;
}

// The two -o flags every scp/ssh in this file shares.
static NSArray<NSString *> *x86SshMuxArgs(void) {
    return @[@"-o", @"BatchMode=yes",
             @"-o", [NSString stringWithFormat:@"ControlPath=%@", x86ControlPath()]];
}

static void x86CloseControlMaster(void) {
    int rc = 0; BOOL to = NO;
    runSubprocess(@"/usr/bin/ssh",
        @[@"-o", [NSString stringWithFormat:@"ControlPath=%@", x86ControlPath()],
          @"-O", @"exit", x86Host()],
        nil, nil, 10.0, &rc, &to);
}

static BOOL x86HostReachable(void) {
    if (x86RunsLocally()) return YES;    // it is this machine; nothing to probe
    static BOOL reachable = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        int rc = 0; BOOL to = NO;
        BOOL ok = runSubprocess(@"/usr/bin/ssh",
            @[@"-o", @"BatchMode=yes", @"-o", @"ConnectTimeout=5",
              x86Host(), @"true"],
            nil, nil, 15.0, &rc, &to);
        reachable = (ok && rc == 0 && !to);
        if (reachable) {
            // Open the shared master. ControlPersist backgrounds it; the
            // atexit closes it so no socket outlives the sweep.
            int mrc = 0; BOOL mto = NO;
            runSubprocess(@"/usr/bin/ssh",
                @[@"-o", @"BatchMode=yes", @"-o", @"ControlMaster=yes",
                  @"-o", [NSString stringWithFormat:@"ControlPath=%@", x86ControlPath()],
                  @"-o", @"ControlPersist=600", x86Host(), @"true"],
                nil, nil, 15.0, &mrc, &mto);
            atexit(x86CloseControlMaster);
        }
        if (!reachable) {
            fprintf(stderr,
              "\n"
              "!! ============================================================\n"
              "!!  x86-64 NOT COVERED — host '%s' is unreachable.\n"
              "!!  Every x86-64 fixture below is scored NOT RUN, not passing.\n"
              "!!  The x86-64 backend is UNTESTED in this sweep.\n"
              "!!  Set XTC_X86_HOST, or bring the host up, to cover it.\n"
              "!! ============================================================\n\n",
              x86Host().UTF8String);
        }
    });
    return reachable;
}

// x86-64 (System V / musl Linux) corpus pipeline — its own honest subprocess
// (xtc -A x86_64), like the m68k and arm9 paths: compile the fixture with the
// real driver into a Linux ELF, copy it to the x86 host, run it there, and diff
// the oracle.
static XTCorpusOutcome runX86_64Pipeline(NSString *xtPath,
                                         NSString *fixBuildDir,
                                         BOOL *outOracled,
                                         NSString **outMessage)
{
    *outMessage = nil;
    *outOracled = NO;
    if (!x86HostReachable()) {
        *outMessage = [NSString stringWithFormat:@"x86 host '%@' unreachable",
                       x86Host()];
        return XTCorpusNotRun;
    }

    NSString *elfPath  = [fixBuildDir stringByAppendingPathComponent:@"fixture-x86_64"];
    NSString *cgStderr = [fixBuildDir stringByAppendingPathComponent:@"x86-compile-stderr.txt"];
    NSString *outPath  = [fixBuildDir stringByAppendingPathComponent:@"stdout-x86_64.txt"];
    NSString *errPath  = [fixBuildDir stringByAppendingPathComponent:@"stderr-x86_64.txt"];
    NSString *rawSource = [NSString stringWithContentsOfFile:xtPath
                                                    encoding:NSUTF8StringEncoding error:NULL];

    // Not -q under XTC_X86_SELFHOST: the driver falls back to clang when the
    // in-house link fails, and without the note on stderr a clang-built binary
    // would be counted as a self-hosted pass.
    NSMutableArray<NSString *> *xtcArgs =
        x86SelfHost() ? [@[@"-A", @"x86_64", @"--self-host"] mutableCopy]
                      : [@[@"-A", @"x86_64", @"-q"] mutableCopy];

    // //xtc-link companion: x86_64 emits a whole-program image like the other
    // honest-subprocess backends, so "link" by compiling the pair as ONE unit.
    NSString *compileInput = xtPath;
    NSString *companion = rawSource ? corpusLinkCompanion(rawSource) : nil;
    if (companion) {
        NSString *compPath = [NSString stringWithFormat:@"%@/%@.xc", kFixtureDir, companion];
        NSString *compSrc = [NSString stringWithContentsOfFile:compPath
                                                      encoding:NSUTF8StringEncoding error:NULL];
        if (compSrc) {
            NSString *merged = [NSString stringWithFormat:@"%@\n%@",
                                stripFunctionPrototypes(rawSource), compSrc];
            NSString *mergedPath = [fixBuildDir stringByAppendingPathComponent:@"x86-merged.xc"];
            if ([merged writeToFile:mergedPath atomically:YES
                           encoding:NSUTF8StringEncoding error:NULL])
                compileInput = mergedPath;
        }
    }
    [xtcArgs addObjectsFromArray:@[compileInput, @"-o", elfPath]];

    int rc = 0; BOOL to = NO;
    BOOL ok = runSubprocess(XCBIN("xcc"), xtcArgs, nil, cgStderr, 60.0, &rc, &to);
    if (!ok || rc != 0 || to) {
        *outMessage = [NSString stringWithFormat:@"xtc -A x86_64 rc=%d%s",
                       rc, to ? " timed out" : ""];
        return XTCorpusFailCodegen;
    }
    if (x86SelfHost()) {
        NSString *note = readFile(cgStderr) ?: @"";
        if ([note rangeOfString:@"retrying with clang"].location != NSNotFound ||
            [note rangeOfString:@"falling back to clang"].location != NSNotFound) {
            *outMessage = @"self-host fell back to clang";
            return XTCorpusFailCodegen;
        }
    }

    if (x86RunsLocally()) {
        // Native: just run it. rc is main()'s return value, not a fault — the
        // oracle below is the verdict, exactly as on the remote path.
        chmod(elfPath.UTF8String, 0755);
        ok = runSubprocess(elfPath, @[], outPath, errPath, kPerFixtureTimeout, &rc, &to);
        if (to)  { *outMessage = @"x86 run timed out"; return XTCorpusFailTimeout; }
        if (!ok) { *outMessage = @"x86 local run failed to start"; return XTCorpusFailRuntime; }
    } else {
    // Ship it to the Linux host and run it there. A unique remote path keeps
    // concurrent / repeat sweeps from stepping on each other.
    NSString *remote = [NSString stringWithFormat:@"/tmp/xtc-corpus-%@-%d",
                        [fixBuildDir lastPathComponent], (int)getpid()];
    NSString *scpTarget = [NSString stringWithFormat:@"%@:%@", x86Host(), remote];
    ok = runSubprocess(@"/usr/bin/scp",
        [@[@"-q"] arrayByAddingObjectsFromArray:
            [x86SshMuxArgs() arrayByAddingObjectsFromArray:@[elfPath, scpTarget]]],
        nil, errPath, 30.0, &rc, &to);
    if (!ok || rc != 0 || to) { *outMessage = @"scp to x86 host failed"; return XTCorpusFailRuntime; }

    // rc is main()'s return value, not a fault — the oracle is the verdict.
    // Remove the binary afterwards so the host doesn't accumulate one per run.
    NSString *cmd = [NSString stringWithFormat:
        @"chmod +x %@ && %@; __rc=$?; rm -f %@; exit $__rc", remote, remote, remote];
    ok = runSubprocess(@"/usr/bin/ssh",
        [x86SshMuxArgs() arrayByAddingObjectsFromArray:@[x86Host(), cmd]],
        outPath, errPath, kPerFixtureTimeout, &rc, &to);
    if (to)  { *outMessage = @"x86 run timed out"; return XTCorpusFailTimeout; }
    if (!ok) { *outMessage = @"ssh to x86 host failed"; return XTCorpusFailRuntime; }
    }

    NSString *name = [fixBuildDir lastPathComponent];
    NSString *archOracle = [NSString stringWithFormat:@"%@/%@.expected.x86_64.out",
                            kFixtureDir, name];
    NSString *expected = [NSString stringWithContentsOfFile:archOracle
                                                   encoding:NSUTF8StringEncoding error:NULL];
    if (!expected) {
        NSString *oraclePath = [NSString stringWithFormat:@"%@/%@.expected.out",
                                kFixtureDir, name];
        expected = [NSString stringWithContentsOfFile:oraclePath
                                             encoding:NSUTF8StringEncoding error:NULL];
    }
    if (expected) {
        *outOracled = YES;
        NSString *actual = readFile(outPath) ?: @"";
        if (![actual isEqualToString:expected]) {
            *outMessage = @"oracle mismatch";
            return XTCorpusFailRuntime;
        }
    }
    return XTCorpusPass;
}

// The arm9 sysroot (the XTOS loader's build dir): supplies libc.so for linking
// and the loader kernel the fixtures run under. Set XTC_ARM9_SYSROOT; when it is
// unset the arm9 leg reports the sysroot as absent.
static NSString *arm9Sysroot(void) {
    const char *env = getenv("XTC_ARM9_SYSROOT");
    // Use a PRIVATE loader build dir. The loader Makefile offers `BUILD=build-<who>`
    // so two builds of that tree do not race: sharing one build dir lets a relink of
    // libc.so tear a file another is packing into a romfs.
    return env ? [NSString stringWithUTF8String:env] : @"";
}

// The loader kernel that hosts the `runhost <path>` + `exit` protocol this
// harness drives. It must be the `make hosttest` build (freertos-hosttest.elf,
// the kernel-resident xtos$ shell), NOT the default `freertos.elf` — that one
// now boots a userspace Lua sh$ shell where `runhost` is a syntax error and
// `exit` never terminates qemu, so every fixture would hang to timeout.
static NSString *arm9Kernel(NSString *sysroot) {
    return [sysroot stringByAppendingPathComponent:@"freertos-hosttest.elf"];
}

// Extract one program's raw output from a loader-shell session transcript.
// The driver script brackets the run with `echo __XB__` / `echo __XE__`, so the
// program's exact bytes are everything between the runhost prompt that follows
// the __XB__ marker and the __XE__ prompt. (Prompt is "xtos$ ".)
static NSString *extractRunhostOutput(NSString *transcript) {
    if (!transcript) return nil;
    // MARKER-FREE. This used to bracket the run with `echo __XB__` / `echo __XE__` —
    // but `echo` is a PROGRAM in the romfs, not a shell builtin, and a private loader
    // build dir (BUILD=build-xtc, which keeps parallel builds from racing) has no
    // /bin/echo. The markers then never printed, extraction returned nil, and EVERY
    // arm9 fixture failed with "no runhost output" — while the programs themselves had
    // run perfectly and printed every line. A test harness that depends on the thing
    // under test having a working /bin is a harness that lies to you.
    //
    // The transcript is: banner, then `xtos$ ` + the program's stdout, then `xtos$ bye`.
    // Strip the prompt prefix and take everything up to the exit.
    NSMutableArray<NSString *> *keep = [NSMutableArray array];
    BOOL started = NO;
    for (NSString *raw in [transcript componentsSeparatedByString:@"\n"]) {
        NSString *line = raw;
        // Strip REPEATEDLY: a program with no output leaves two prompts on one
        // line (`xtos$ xtos$ bye` — the post-run prompt and the exit echo), and
        // a single strip left `xtos$ bye`, which then failed the `bye` match
        // below and surfaced as a phantom oracle mismatch on every arm9
        // fixture whose expected output is empty (asm_sp_shifted_add).
        while ([line hasPrefix:@"xtos$ "]) line = [line substringFromIndex:6];
        if ([line isEqualToString:@"xtos$"]) line = @"";
        if ([line containsString:@"XTOS shell"]) { started = YES; continue; }  // banner
        if (!started) continue;
        if ([line isEqualToString:@"bye"]) break;                              // exit
        [keep addObject:line];
    }
    if (!started) return nil;
    // Trim trailing blanks the shell leaves behind.
    while (keep.count && [keep.lastObject length] == 0) [keep removeLastObject];
    return [[keep componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
}

// ARMv7-A (Zynq Cortex-A9) corpus pipeline — its OWN honest subprocess, like
// the m68k path: compile the fixture with the real driver (xtc -A arm9) into a
// loader-hosted PIC .so whose heap runtime imports malloc from libc.so, then run
// it on the XTOS loader kernel under qemu via the `runhost` shell builtin (one
// qemu launch per fixture, no kernel rebuild), and diff the oracle. The fixture
// still prints through xtc's own runtime, so the captured bytes match the same
// oracle as before — only the allocator now comes from libc.so.
static XTCorpusOutcome runArm9Pipeline(NSString *xtPath,
                                       NSString *fixBuildDir,
                                       BOOL *outOracled,
                                       NSString **outMessage)
{
    *outMessage = nil;
    *outOracled = NO;
    NSString *sysroot  = arm9Sysroot();
    NSString *kernel   = arm9Kernel(sysroot);
    NSString *libc     = [sysroot stringByAppendingPathComponent:@"libc.so"];
    NSFileManager *fm  = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:kernel] || ![fm fileExistsAtPath:libc]) {
        *outMessage = [NSString stringWithFormat:
            @"arm9 kernel/libc absent (%@): build the XTOS loader's hosttest kernel "
            @"and set XTC_ARM9_SYSROOT", sysroot];
        return XTCorpusFailRuntime;
    }

    NSString *soPath     = [fixBuildDir stringByAppendingPathComponent:@"fixture-arm9.so"];
    NSString *cgStderr   = [fixBuildDir stringByAppendingPathComponent:@"arm9-compile-stderr.txt"];
    NSString *qemuOut    = [fixBuildDir stringByAppendingPathComponent:@"arm9-qemu-stdout.txt"];
    NSString *qemuErr    = [fixBuildDir stringByAppendingPathComponent:@"arm9-qemu-stderr.txt"];
    NSString *progOut    = [fixBuildDir stringByAppendingPathComponent:@"stdout-arm9.txt"];
    NSString *rawSource  = [NSString stringWithContentsOfFile:xtPath
                                                     encoding:NSUTF8StringEncoding error:NULL];

    NSMutableArray<NSString *> *xtcArgs = [@[@"-A", @"arm9", @"-q", @"-L", sysroot] mutableCopy];

    // //xtc-link companion: arm9 emits a whole-program image like xt6502/m68k,
    // so "link" by compiling the pair as ONE unit (strip caller prototypes +
    // append the companion definitions).
    NSString *compileInput = xtPath;
    NSString *companion = rawSource ? corpusLinkCompanion(rawSource) : nil;
    if (companion) {
        NSString *compPath = [NSString stringWithFormat:@"%@/%@.xc", kFixtureDir, companion];
        NSString *compSrc = [NSString stringWithContentsOfFile:compPath
                                                      encoding:NSUTF8StringEncoding error:NULL];
        if (compSrc) {
            NSString *merged = [NSString stringWithFormat:@"%@\n%@",
                                stripFunctionPrototypes(rawSource), compSrc];
            NSString *mergedPath = [fixBuildDir stringByAppendingPathComponent:@"arm9-merged.xc"];
            if ([merged writeToFile:mergedPath atomically:YES
                           encoding:NSUTF8StringEncoding error:NULL])
                compileInput = mergedPath;
        }
    }
    [xtcArgs addObjectsFromArray:@[compileInput, @"-o", soPath]];

    int rc = 0; BOOL to = NO;
    BOOL ok = runSubprocess(XCBIN("xcc"), xtcArgs, nil, cgStderr, 60.0, &rc, &to);
    if (!ok || rc != 0 || to) {
        *outMessage = [NSString stringWithFormat:@"xtc -A arm9 rc=%d%s",
                       rc, to ? " timed out" : ""];
        return XTCorpusFailCodegen;
    }

    // Run on the XTOS loader kernel: feed the shell a runhost script over stdin,
    // bracketed with echo markers so the program's exact output is recoverable
    // from the session transcript (qemu binds semihosting I/O to its stdio).
    NSString *script = [NSString stringWithFormat:@"runhost %@\nexit\n", soPath];
    ok = runSubprocessWithStdin(@"/usr/bin/env",
        @[@"qemu-system-arm", @"-M", @"xilinx-zynq-a9", @"-display", @"none",
          @"-no-reboot", @"-m", @"1024", @"-chardev", @"stdio,id=sh0",
          @"-semihosting-config", @"enable=on,target=native,chardev=sh0",
          @"-kernel", kernel],
        script, qemuOut, qemuErr, kPerFixtureTimeout, &rc, &to);
    if (to)  { *outMessage = @"qemu timed out"; return XTCorpusFailTimeout; }
    if (!ok) { *outMessage = @"qemu spawn failed"; return XTCorpusFailRuntime; }

    NSString *transcript = readFile(qemuOut) ?: @"";
    NSString *actualOut = extractRunhostOutput(transcript);
    if (!actualOut) { *outMessage = @"loader: no runhost output (load failed?)"; return XTCorpusFailRuntime; }
    [actualOut writeToFile:progOut atomically:YES encoding:NSUTF8StringEncoding error:NULL];

    NSString *name = [fixBuildDir lastPathComponent];
    NSString *archOracle = [NSString stringWithFormat:@"%@/%@.expected.arm9.out", kFixtureDir, name];
    NSString *expected = [NSString stringWithContentsOfFile:archOracle
                                                   encoding:NSUTF8StringEncoding error:NULL];
    if (!expected) {
        NSString *oraclePath = [NSString stringWithFormat:@"%@/%@.expected.out", kFixtureDir, name];
        expected = [NSString stringWithContentsOfFile:oraclePath
                                             encoding:NSUTF8StringEncoding error:NULL];
    }
    if (expected) {
        *outOracled = YES;
        NSString *actual = readFile(progOut) ?: @"";
        if (![actual isEqualToString:expected]) { *outMessage = @"oracle mismatch"; return XTCorpusFailRuntime; }
    }
    return XTCorpusPass;
}

static XTCorpusOutcome runXt6502Pipeline(XTIRModule *mod,
                                          XTIRFunction *entry,
                                          NSString *fixBuildDir,
                                          BOOL *outOracled,
                                          NSString **outMessage)
{
    *outMessage = nil;
    *outOracled = NO;

    // Run the IR opt pipeline at the -O3 default (the production level), with
    // the xt6502 profile — so the in-process corpus tests what users ship, not
    // raw -O0 lowering. (Lower levels are debug aids, not the headline.)
    {
        XTIROptPipeline *pipe =
            [XTIROptPipeline standardPipelineAtLevel:3
                                             profile:[XTIRXt6502TargetProfile new]];
        NSMutableArray<NSString *> *poErrs = nil;
        if (![pipe runOnModule:mod errors:&poErrs]) {
            *outMessage = [NSString stringWithFormat:@"opt pipeline failed: %@",
                           poErrs.firstObject ?: @"(no detail)"];
            return XTCorpusFailCodegen;
        }
    }

    XTDiagnosticEngine *diag = [[XTDiagnosticEngine alloc] init];
    NSString *asmText = nil;
    @try {
        asmText = [XT6502Backend assemblyFromModule:mod
                                        memoryModel:xt6502CorpusModel()
                                        diagnostics:diag];
    } @catch (NSException *e) {
        *outMessage = [NSString stringWithFormat:@"codegen exception: %@", e.reason];
        return XTCorpusFailCodegen;
    }
    if (!asmText || diag.hasFatalError) {
        NSString *firstErr = @"backend rejected";
        for (XTDiagnostic *d in diag.diagnostics) {
            if (d.level >= 2) { firstErr = d.message; break; }
        }
        *outMessage = firstErr;
        return XTCorpusFailCodegen;
    }

    // The SAME asm-text peephole `xtcg-6502` runs. Without it this path was
    // measuring code no user ever gets: ~1 KB larger on a mid-sized fixture,
    // because the SSA→stack lowering opens redundant reload / dead store
    // patterns that only this pass closes.
    //
    // It is not a cosmetic difference. `gfx6_vline` passed through the
    // subprocess and failed here, and the un-peepholed build died on a
    // `JMP ($0085)` through a null vector — so the harness was reporting a
    // failure the product does not have, on a fixture sitting close enough to
    // a size boundary for the extra bytes to matter. Gated at -O>=1 exactly as
    // the subprocess gates it, so -O0 output stays straight-line.
    // 3 == the -O3 the IR pipeline above is run at; the sweep has no lower
    // level, so this is unconditional rather than gated on a variable.
    asmText = [XT6502AsmPeephole optimise:asmText level:3];

    // Rename the entry function so the harness's `JSR _xt_main`
    // lands, mirroring the arm64 path.
    if ([entry.name isEqualToString:@"main"]) {
        asmText = renameSymbol(asmText, @"main", @"xt_main");
    } else {
        // Non-main entry — rename to xt_main so the harness's
        // JSR resolves consistently.
        asmText = renameSymbol(asmText, entry.name, @"xt_main");
    }

    NSString *combined = buildXt6502Stub(mod, asmText);
    NSString *combinedPath = [fixBuildDir stringByAppendingPathComponent:@"combined.asm"];
    NSString *xexPath = [fixBuildDir stringByAppendingPathComponent:@"fixture.xex"];
    NSString *stdoutPath = [fixBuildDir stringByAppendingPathComponent:@"stdout-6502.txt"];
    NSString *stderrPath = [fixBuildDir stringByAppendingPathComponent:@"stderr-6502.txt"];

    [combined writeToFile:combinedPath atomically:YES
                encoding:NSUTF8StringEncoding error:NULL];

    int rc = 0;
    BOOL timedOut = NO;
    // Banked assembly + simulation on the xt map (task #60). `-L`
    // gives xta the layout's [banking] config (code window $6000-$9FFF
    // via $82); `-m xt` routes that window through the sim's
    // code-bank array. Small fixtures stay unbanked (bank 0) and the
    // banked machinery is inert; large ones overflow into code banks.
    // `-I .` lets the harness's `.include "support/xt6502/asm/…"` (the real
    // arithmetic runtime) resolve from the project root — combined.asm
    // lives under build/corpus/<name>/, so the project root must be on the
    // include search path.
    BOOL spawnOK = runSubprocess(XCBIN("xcc-as"),
        // -I support as well as -I .: the generated runtime `.include` lines are
        // relative to the SUPPORT ROOT (support/ here, lib/xc in an install).
        @[@"-L", @"support/xt6502/layouts/xt.lnk", @"-I", @".", @"-I", @"support",
          @"-o", xexPath, combinedPath],
        nil, stderrPath, 30.0, &rc, &timedOut);
    if (!spawnOK || rc != 0) {
        *outMessage = [NSString stringWithFormat:@"xta rc=%d", rc];
        return XTCorpusFailAssembleLink;
    }

    spawnOK = runSubprocess(XCBIN("xcc-sim-6502"),
        @[@"-m", @"xt", @"-d", xexPath],
        stdoutPath, stderrPath,
        kPerFixtureTimeout, &rc, &timedOut);
    if (timedOut) {
        *outMessage = [NSString stringWithFormat:@"xts timed out after %.0fs", kPerFixtureTimeout];
        return XTCorpusFailTimeout;
    }
    if (!spawnOK || xtsAborted(stderrPath)) {
        *outMessage = [NSString stringWithFormat:@"xts aborted (rc=%d)", rc];
        return XTCorpusFailRuntime;
    }

    // Oracle diff. Prefer a per-backend `<name>.expected.xt6502.out`
    // when present (fixtures whose float-precision or PRNG path
    // genuinely diverges from arm64, e.g. ahl); fall back to the
    // common `<name>.expected.out` otherwise.
    NSString *name = [fixBuildDir lastPathComponent];
    NSString *archOraclePath = [NSString stringWithFormat:
        @"%@/%@.expected.xt6502.out", kFixtureDir, name];
    NSString *expected = [NSString stringWithContentsOfFile:archOraclePath
                                                   encoding:NSUTF8StringEncoding
                                                      error:NULL];
    if (!expected) {
        NSString *oraclePath = [NSString stringWithFormat:
            @"%@/%@.expected.out", kFixtureDir, name];
        expected = [NSString stringWithContentsOfFile:oraclePath
                                             encoding:NSUTF8StringEncoding
                                                error:NULL];
    }
    if (expected) {
        *outOracled = YES;
        NSString *actual = readFile(stdoutPath) ?: @"";
        if (![actual isEqualToString:expected]) {
            NSArray<NSString *> *expLines = [expected componentsSeparatedByString:@"\n"];
            NSArray<NSString *> *actLines = [actual componentsSeparatedByString:@"\n"];
            NSUInteger firstDiff = NSNotFound;
            NSUInteger commonLen = MIN(expLines.count, actLines.count);
            for (NSUInteger i = 0; i < commonLen; i++) {
                if (![expLines[i] isEqualToString:actLines[i]]) {
                    firstDiff = i; break;
                }
            }
            if (firstDiff == NSNotFound) firstDiff = commonLen;
            NSString *expLine = firstDiff < expLines.count
                ? expLines[firstDiff] : @"<end>";
            NSString *actLine = firstDiff < actLines.count
                ? actLines[firstDiff] : @"<end>";
            *outMessage = [NSString stringWithFormat:
                @"oracle mismatch at line %lu: expected '%@' got '%@'",
                (unsigned long)firstDiff + 1, expLine, actLine];
            return XTCorpusFailRuntime;
        }
    }
    return XTCorpusPass;
}

// Run the xt6502 production subprocess pipeline on the same fixture:
// spawn `<bin>/xcc -fnew-ir -m xt <fix>.xc -o <build>/subproc.xex`
// (which internally chains xtc-fe → xtcg-6502 → xta), then run xts
// and diff captured stdout against the expected oracle. Returns YES
// on full pass; on failure sets *outMessage with a one-line gist
// suitable for the report.
static NSString *corpusLinkCompanion(NSString *rawSource); // defined below
static NSString *stripFunctionPrototypes(NSString *src);   // defined below

static BOOL runXt6502SubprocessPipeline(NSString *xtPath,
                                         NSString *fixBuildDir,
                                         NSString **outMessage)
{
    *outMessage = nil;
    NSString *xexPath    = [fixBuildDir stringByAppendingPathComponent:@"subproc.xex"];
    NSString *stdoutPath = [fixBuildDir stringByAppendingPathComponent:@"subproc-stdout.txt"];
    NSString *stderrPath = [fixBuildDir stringByAppendingPathComponent:@"subproc-stderr.txt"];

    NSMutableArray<NSString *> *xtcArgs = [@[@"-fnew-ir", @"-m", @"xt", @"-q"]
                                           mutableCopy];
    NSString *rawSource = [NSString stringWithContentsOfFile:xtPath
                                                    encoding:NSUTF8StringEncoding
                                                       error:NULL];
    // Cross-module companion (`//xtc-link: <fixture>`): xt6502 emits a
    // whole-program image, not a relocatable object, so the only way to
    // "link" is to compile the pair as ONE unit — exactly as the
    // in-process path does. Build the merged source (caller prototypes
    // stripped, companion appended) into the fixture build dir and feed
    // THAT to xtc; otherwise the companion's functions are undefined
    // (JSR $0000 → crash → empty output).
    NSString *compileInput = xtPath;
    NSString *companion = rawSource ? corpusLinkCompanion(rawSource) : nil;
    if (companion) {
        NSString *compPath = [NSString stringWithFormat:@"%@/%@.xc",
                              kFixtureDir, companion];
        NSString *compSrc = [NSString stringWithContentsOfFile:compPath
                                                      encoding:NSUTF8StringEncoding
                                                         error:NULL];
        if (compSrc) {
            NSString *merged = [NSString stringWithFormat:@"%@\n%@",
                                stripFunctionPrototypes(rawSource), compSrc];
            NSString *mergedPath = [fixBuildDir
                stringByAppendingPathComponent:@"subproc-merged.xc"];
            if ([merged writeToFile:mergedPath atomically:YES
                           encoding:NSUTF8StringEncoding error:NULL]) {
                compileInput = mergedPath;
            }
        }
    }
    [xtcArgs addObjectsFromArray:@[compileInput, @"-o", xexPath]];

    int rc = 0; BOOL to = NO;
    BOOL ok = runSubprocess(XCBIN("xcc"), xtcArgs,
        nil, stderrPath, 30.0, &rc, &to);
    if (!ok || rc != 0 || to) {
        *outMessage = [NSString stringWithFormat:@"xtc -fnew-ir rc=%d%s",
                       rc, to ? " timed out" : ""];
        return NO;
    }
    // xtc -fnew-ir does its own xta invocation when -o ends in .xex, so
    // the xex is ready to run.
    ok = runSubprocess(XCBIN("xcc-sim-6502"),
        @[@"-m", @"xt", @"-d", xexPath],
        stdoutPath, stderrPath,
        kPerFixtureTimeout, &rc, &to);
    if (to) {
        *outMessage = [NSString stringWithFormat:@"xts timed out after %.0fs",
                       kPerFixtureTimeout];
        return NO;
    }
    if (!ok || xtsAborted(stderrPath)) {
        *outMessage = [NSString stringWithFormat:@"xts aborted (rc=%d)", rc];
        return NO;
    }

    NSString *name = [fixBuildDir lastPathComponent];
    NSString *archOraclePath = [NSString stringWithFormat:
        @"%@/%@.expected.xt6502.out", kFixtureDir, name];
    NSString *expected = [NSString stringWithContentsOfFile:archOraclePath
                                                   encoding:NSUTF8StringEncoding
                                                      error:NULL];
    if (!expected) {
        NSString *oraclePath = [NSString stringWithFormat:
            @"%@/%@.expected.out", kFixtureDir, name];
        expected = [NSString stringWithContentsOfFile:oraclePath
                                             encoding:NSUTF8StringEncoding
                                                error:NULL];
    }
    if (!expected) return YES;   // un-oracled — rc==0 alone passes
    NSString *actual = readFile(stdoutPath) ?: @"";
    if ([actual isEqualToString:expected]) return YES;

    NSArray<NSString *> *expLines = [expected componentsSeparatedByString:@"\n"];
    NSArray<NSString *> *actLines = [actual componentsSeparatedByString:@"\n"];
    NSUInteger firstDiff = NSNotFound;
    NSUInteger commonLen = MIN(expLines.count, actLines.count);
    for (NSUInteger i = 0; i < commonLen; i++) {
        if (![expLines[i] isEqualToString:actLines[i]]) { firstDiff = i; break; }
    }
    if (firstDiff == NSNotFound) firstDiff = commonLen;
    NSString *expLine = firstDiff < expLines.count ? expLines[firstDiff] : @"<end>";
    NSString *actLine = firstDiff < actLines.count ? actLines[firstDiff] : @"<end>";
    *outMessage = [NSString stringWithFormat:
        @"oracle mismatch at line %lu: expected '%@' got '%@'",
        (unsigned long)firstDiff + 1, expLine, actLine];
    return NO;
}

// Set every outcome slot — top-level + per-backend — to the same
// failure value. Used at each shared-frontend early-return point
// (preproc / parse / sema / lower / verify) where neither backend
// got a chance to run; without this, the per-backend outcomes
// default to XTCorpusPass (enum 0) and the renderer's
// `r.arm64Outcome == XTCorpusPass` counter spuriously fires for
// every shared-frontend-failed fixture.
static void failBothBackends(XTCorpusResult *r, XTCorpusOutcome outcome) {
    r.outcome = outcome;
    r.arm64Outcome = outcome;
    r.xt6502Outcome = outcome;
}

// Run the shared frontend (preproc → lex → parse → sema → lower →
// verify → pick entry) for ONE backend's include paths, so each backend
// resolves its own platform library — the arm64 Stdio (ASCII → `_putc`
// → stdout) for arm64, the Atari Stdio (screen RAM) for xt6502. On
// success returns YES and sets *outMod / *outEntry; on failure returns
// NO and sets *outcome / *msg. The arch-neutral lowering is the same
// code either way; only the imported platform sources differ.
static BOOL corpusFrontend(NSString *rawSource, NSString *xtPath,
                           NSString *name,
                           NSArray<NSString *> *includePaths,
                           XTPointerPlacement defaultPlacement,
                           XTIRModule **outMod, XTIRFunction **outEntry,
                           XTCorpusOutcome *outcome, NSString **msg) {
    *outMod = nil; *outEntry = nil;
    XTDiagnosticEngine *diag = [[XTDiagnosticEngine alloc] init];
    XTPreprocessor *pp = [[XTPreprocessor alloc] initWithDiagnostics:diag];
    pp.includePaths = includePaths;

    // Surface the layout's formatter-buffer addresses as preprocessor macros
    // (the old driver's definePrintfBufferMacros). The atari Stdio source +
    // its inline asm reference XT_STDIO_FMT_BUF / XT_PRINTF_BUF symbolically;
    // without these defines they leak as undefined ($0000) symbols. Values
    // come from the xt layout's buffers (defaulted in XTMemoryModel). The
    // arm64 host Stdio doesn't use them, so defining them on both lowerings
    // is harmless.
    XTMemoryModel *bufModel = xt6502CorpusModel();
    NSArray *fmtR = bufModel.buffers[@"stdio_fmt"];
    NSUInteger fmtB = (fmtR.count == 2) ? [fmtR[0] unsignedIntegerValue] : 0;
    NSArray *pfR = bufModel.buffers[@"printf"];
    NSUInteger pfB = (pfR.count == 2) ? [pfR[0] unsignedIntegerValue] : 0;
    [pp defineMacro:@"XT_STDIO_FMT_BUF" value:[NSString stringWithFormat:@"$%04lX", (unsigned long)fmtB]];
    [pp defineMacro:@"XT_PRINTF_BUF" value:[NSString stringWithFormat:@"$%04lX", (unsigned long)pfB]];
    [pp defineMacro:@"XT_PRINTF_DATA_BUF" value:[NSString stringWithFormat:@"$%04lX", (unsigned long)(pfB + 2)]];

    // `bank(BANK_TYPE, idx)` builtin selectors — the old driver predefined
    // these (XTCompilerDriver.m.old-codegen); the new pipeline must too, or a
    // `bank(BANK_DATA, …)` call sees BANK_DATA as an undefined identifier.
    // 0/1/2 match the window order sema's resolveBankBuiltin decodes.
    [pp defineMacro:@"BANK_DATA" value:@"0"];
    [pp defineMacro:@"BANK_CODE" value:@"1"];
    [pp defineMacro:@"BANK_C"    value:@"2"];

    // Target arch sentinel — `#if ARCH_<arch>` gates arch-specific
    // inline asm and library overlays. The arm64 backend assembles asm
    // bodies verbatim through clang's integrated assembler (phase-171),
    // so 6502 mnemonics in shared library code (Foundation, etc.) must
    // be wrapped in `#if ARCH_6502 ... #endif` and the arm64 branch
    // either left empty (no-op) or filled with an equivalent.
    if (defaultPlacement == XTPointerPlacementMain) {
        [pp defineMacro:@"ARCH_arm64" value:@"1"];
    } else {
        [pp defineMacro:@"ARCH_6502" value:@"1"];
    }

    // The implicit platform prelude, exactly as the driver applies it (task
    // #36): without this the corpus compiles a DIFFERENT unit than a real
    // `xcc` invocation — the 28 fixtures that #include'd Stdio passed here
    // and failed every real build, which is precisely the blindness the
    // corpus exists to prevent.
    {
        NSFileManager *pfm = [NSFileManager defaultManager];
        for (NSString *dir in includePaths) {
            if ([pfm fileExistsAtPath:
                    [dir stringByAppendingPathComponent:@"Platform.xc"]]) {
                pp.platformPrelude = @"Platform.xc";
                break;
            }
        }
    }

    // Mirror XTCompilerDriver.setupObjectFmtGateOnto: — gate the `%@` / Object
    // dependency by a throwaway preprocess of the fully-expanded source (the
    // spec may live in an imported library; the preprocessor strips comments so
    // Stdio's own doc lines don't count). This is the only printf format-feature
    // gate left after phase-559 removed the xt6502-only width/float gates — it
    // fences off a heavy dependency, not just a code branch, and every backend's
    // Stdio uses it. (support/6502 parks the flat-6502 Stdio that still gates
    // widths/floats too.)
    XTPreprocessor *scanPP = [[XTPreprocessor alloc]
        initWithDiagnostics:[[XTDiagnosticEngine alloc] init]];
    scanPP.includePaths = includePaths;
    [scanPP defineMacro:@"XT_STDIO_FMT_BUF" value:[NSString stringWithFormat:@"$%04lX", (unsigned long)fmtB]];
    [scanPP defineMacro:@"XT_PRINTF_BUF" value:[NSString stringWithFormat:@"$%04lX", (unsigned long)pfB]];
    [scanPP defineMacro:@"XT_PRINTF_DATA_BUF" value:[NSString stringWithFormat:@"$%04lX", (unsigned long)(pfB + 2)]];
    if (defaultPlacement == XTPointerPlacementMain) {
        [scanPP defineMacro:@"ARCH_arm64" value:@"1"];
    } else {
        [scanPP defineMacro:@"ARCH_6502" value:@"1"];
    }
    NSString *scanExpanded = nil;
    @try { scanExpanded = [scanPP preprocessSource:rawSource filename:xtPath]; }
    @catch (NSException *e) { scanExpanded = rawSource; }
    if (!scanExpanded) scanExpanded = rawSource;
    BOOL hasAtFmt = [scanExpanded rangeOfString:@"%@"].location != NSNotFound;
    [pp defineMacro:@"HAS_ATFMT" value:hasAtFmt ? @"1" : @"0"];

    // Surface the heap pointer width so foundation-library inline asm
    // (Array.xc / Map.xc / Set.xc) can select the correct bank-byte
    // load pattern for the current pointer width.
    [pp defineMacro:@"XTC_POINTER_WIDTH" value:@"4"];

    NSString *source = nil;
    @try {
        source = [pp preprocessSource:rawSource filename:xtPath];
    } @catch (NSException *e) {
        *outcome = XTCorpusFailPreproc;
        *msg = [NSString stringWithFormat:@"preproc exception: %@", e.reason];
        return NO;
    }
    if (!source || diag.hasFatalError) {
        *outcome = XTCorpusFailPreproc;
        NSString *firstErr = @"preprocessor error";
        for (XTDiagnostic *d in diag.diagnostics) {
            if (d.level >= 2) { firstErr = d.message; break; }
        }
        *msg = firstErr;
        return NO;
    }

    XTLexer *lexer = [[XTLexer alloc] initWithSource:source
                                            filename:xtPath.lastPathComponent
                                         diagnostics:diag];
    NSArray<XTToken *> *tokens = nil;
    @try {
        tokens = [lexer tokenise];
    } @catch (NSException *e) {
        *outcome = XTCorpusFailParse;
        *msg = [NSString stringWithFormat:@"lex exception: %@", e.reason];
        return NO;
    }
    if (diag.hasFatalError) { *outcome = XTCorpusFailParse; *msg = @"lexer error"; return NO; }

    XTTypeTable *tt = [[XTTypeTable alloc] init];
    XTParser *parser = [[XTParser alloc] initWithTokens:tokens
                                              typeTable:tt diagnostics:diag];
    parser.defaultPointerPlacement = defaultPlacement;
    XTProgramNode *ast = nil;
    @try {
        ast = [parser parse];
    } @catch (NSException *e) {
        *outcome = XTCorpusFailParse;
        *msg = [NSString stringWithFormat:@"parse exception: %@", e.reason];
        return NO;
    }
    if (!ast || diag.hasFatalError) {
        if (getenv("XTC_DEBUG_PARSE")) {
            for (XTDiagnostic *d in diag.diagnostics) {
                fprintf(stderr, "  parse: %s\n", d.message.UTF8String);
            }
        }
        *outcome = XTCorpusFailParse;
        *msg = @"parse error";
        return NO;
    }

    // uxkit/026: a class with an `outlet` field or an `:action` method
    // auto-conforms to the binding protocol and has its setOutlet/wireAction
    // bodies synthesised. BEFORE sema, so conformance checking sees them — this
    // sweep reimplements the driver's pipeline, and skipping the pass made it
    // report "does not conform" for a fixture the driver compiled and ran.
    ast = [XTDesignableSynthesis run:ast typeTable:tt
                                arm64:(defaultPlacement == XTPointerPlacementMain)
                          diagnostics:diag];
    if (diag.hasFatalError || diag.errorCount > 0) {
        *outcome = XTCorpusFailSema;
        *msg = diag.diagnostics.firstObject.message ?: @"designable synthesis error";
        return NO;
    }

    XTSemanticAnalyzer *sema = [[XTSemanticAnalyzer alloc] initWithTypeTable:tt
                                                                diagnostics:diag];
    // The corpus ships the real free-list heap (xt6502 embeds
    // heap.asm/retain.asm; arm64 malloc/free + dealloc dispatch), so it
    // is a -falloc=heap target — without this the analyzer defaults to
    // "bump" and rejects every delete/release/retain. heapBank is the
    // first reserved heap bank: 1 for the xt6502 banked data-page heap
    // (placement=Heap), 0 for the arm64 flat heap (placement=Main).
    sema.allocator = @"heap";
    sema.heapBank  = (defaultPlacement == XTPointerPlacementHeap) ? 1 : 0;
    // ARC is unconditional. `-farc=off` is retired (bug 026): it never
    // reached the IR lowering, so every fixture that carried it was an ARC
    // build regardless, and the per-fixture directive scan that used to sit
    // here selected a mode that did not exist.
    @try {
        [sema analyzeProgram:ast];
    } @catch (NSException *e) {
        *outcome = XTCorpusFailSema;
        *msg = [NSString stringWithFormat:@"sema exception: %@", e.reason];
        return NO;
    }
    if (diag.hasFatalError) {
        *outcome = XTCorpusFailSema;
        NSString *first = @"sema error";
        for (XTDiagnostic *d in diag.diagnostics) {
            if (d.level >= 2) { first = d.message; break; }   // first error-level
        }
        *msg = first;
        return NO;
    }

    XTIRModule *mod = nil;
    @try {
        // The in-process path lowers ONE module shared by the arm64 and xt6502
        // backends, so it can't carry a target-specific vtable layout. These
        // fixtures are all single-module, where the compile-time-subtree downcast is
        // complete — so lower without the runtime-ancestry parent slot (which xt6502's
        // banked pointers can't walk). Cross-`.so` ancestry is covered by the driver
        // (subprocess path) and the dedicated cross-module tests.
        [XTIRLowering setVtableAncestry:NO];
        mod = [XTIRLowering lowerProgram:ast moduleName:name diagnostics:diag];
    } @catch (NSException *e) {
        *outcome = XTCorpusFailLower;
        *msg = [NSString stringWithFormat:@"lower exception: %@", e.reason];
        return NO;
    }
    for (XTDiagnostic *d in diag.diagnostics) {
        if ([d.message hasPrefix:@"ABANDON|"]) {
            tallyReason(gLowerReasons, gLowerExamples, d.message, name);
        }
    }
    if (mod && getenv("XTC_DUMP_IR")) {
        NSString *irTxt = [XTIRPrinter stringFromModule:mod];
        [irTxt writeToFile:[NSString stringWithFormat:@"/tmp/dump-%@.ir", name]
                atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }
    if (!mod || diag.hasFatalError) {
        *outcome = XTCorpusFailLower;
        NSString *firstErr = @"lowering rejected";
        for (XTDiagnostic *d in diag.diagnostics) {
            if (d.level >= 2) { firstErr = d.message; break; }
        }
        *msg = firstErr;
        return NO;
    }

    NSArray<NSString *> *vErrs = nil;
    BOOL verified = NO;
    @try {
        verified = [XTIRVerifier verifyModule:mod errors:&vErrs];
    } @catch (NSException *e) {
        *outcome = XTCorpusFailVerify;
        *msg = [NSString stringWithFormat:@"verifier exception: %@", e.reason];
        return NO;
    }
    if (!verified) {
        *outcome = XTCorpusFailVerify;
        *msg = vErrs.firstObject ?: @"verifier rejected";
        return NO;
    }

    XTIRFunction *entry = pickEntryFunction(mod);
    if (!entry) {
        *outcome = XTCorpusFailNoFunctions;
        *msg = @"no function with a body to call";
        return NO;
    }
    *outMod = mod; *outEntry = entry;
    return YES;
}

// Per-fixture `target=` directive (extends the `//xtc-flags:` mechanism).
// A fixture that is fundamentally tied to one backend — e.g. its body is
// inline 6502 assembly (Memory.memset) that can't run on arm64 — declares
// `//xtc-flags: target=xt6502` (or `target=arm64`) so the dual-backend
// pass requirement is scoped to the backend it can actually target. The
// other backend's per-arch result is still measured honestly; only the
// COMBINED "both backends pass" verdict ignores the untargeted backend.
// Default (no directive) is `target=both`. Returns: 0 = both, 1 = arm64
// only, 2 = xt6502 only. Only structured `//xtc-flags:` lines are honoured
// (prose mentioning "target=" in a comment doesn't trigger it).
typedef NS_ENUM(NSInteger, XTCorpusTarget) {
    XTCorpusTargetBoth = 0,
    XTCorpusTargetArm64Only = 1,
    XTCorpusTargetXt6502Only = 2,
    XTCorpusTargetAtariStOnly = 3,
    XTCorpusTargetArm9Only = 4,
};
static XTCorpusTarget corpusTargetForSource(NSString *rawSource) {
    for (NSString *line in [rawSource componentsSeparatedByString:@"\n"]) {
        NSString *t = [line stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];
        if (![t hasPrefix:@"//xtc-flags:"] && ![t hasPrefix:@"// xtc-flags:"]) continue;
        if ([t rangeOfString:@"target=xt6502"].location != NSNotFound)
            return XTCorpusTargetXt6502Only;
        // "target=arm9" must be checked before "target=arm64" — neither is a
        // prefix of the other, but keep both explicit.
        if ([t rangeOfString:@"target=arm9"].location != NSNotFound)
            return XTCorpusTargetArm9Only;
        if ([t rangeOfString:@"target=arm64"].location != NSNotFound)
            return XTCorpusTargetArm64Only;
        if ([t rangeOfString:@"target=atarist"].location != NSNotFound)
            return XTCorpusTargetAtariStOnly;
    }
    return XTCorpusTargetBoth;
}

// Canonical backend names used throughout the per-backend / applicability logic.
static NSString *const kBackendArm64  = @"arm64";
static NSString *const kBackendXt6502 = @"xt6502";
static NSString *const kBackendM68k   = @"m68k";
static NSString *const kBackendArm9   = @"arm9";
static NSString *const kBackendX86    = @"x86_64";

// The set of backends a fixture is NOT applicable to — excluded from each
// backend's pass/total count because the fixture genuinely cannot run there
// (a real per-platform feature gap, never a way to hide a bug). Sources:
//
//   //xtc-na: <backend>[,<backend>] — <reason>   (preferred; reason required)
//   //xtc-flags: target=X                        (legacy: NA on all but X)
//
// Default (neither present) = applies to ALL FOUR backends, so an unmarked
// fixture that fails any backend is a genuine, visible failure. Every exclusion
// must name an explicit reason after an em-dash / `--` / `:` so the audit can be
// re-checked. `atarist` is accepted as an alias for `m68k`.
static NSSet<NSString *> *corpusNASetForSource(NSString *rawSource) {
    NSMutableSet<NSString *> *na = [NSMutableSet set];
    void (^add)(NSString *) = ^(NSString *tok) {
        NSString *b = [tok stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]].lowercaseString;
        if ([b isEqualToString:@"atarist"]) b = kBackendM68k;
        if ([@[kBackendArm64, kBackendXt6502, kBackendM68k, kBackendArm9,
               kBackendX86] containsObject:b])
            [na addObject:b];
    };
    for (NSString *line in [rawSource componentsSeparatedByString:@"\n"]) {
        NSString *t = [line stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];
        NSRange r = [t rangeOfString:@"//xtc-na:"];
        if (r.location == NSNotFound) r = [t rangeOfString:@"// xtc-na:"];
        if (r.location == NSNotFound) continue;
        NSString *rest = [t substringFromIndex:r.location + r.length];
        // Cut the reason off at the first em-dash / `--` / `:` separator.
        for (NSString *sep in @[@"—", @"--", @":"]) {
            NSRange sr = [rest rangeOfString:sep];
            if (sr.location != NSNotFound) { rest = [rest substringToIndex:sr.location]; break; }
        }
        for (NSString *tok in [rest componentsSeparatedByString:@","]) add(tok);
    }
    // Legacy target=X → NA on every other backend.
    XTCorpusTarget tg = corpusTargetForSource(rawSource);
    NSArray<NSString *> *all = @[kBackendArm64, kBackendXt6502, kBackendM68k,
                                 kBackendArm9, kBackendX86];
    NSString *only = tg == XTCorpusTargetArm64Only ? kBackendArm64
                   : tg == XTCorpusTargetXt6502Only ? kBackendXt6502
                   : tg == XTCorpusTargetAtariStOnly ? kBackendM68k
                   : tg == XTCorpusTargetArm9Only ? kBackendArm9 : nil;
    if (only) for (NSString *b in all) if (![b isEqualToString:only]) [na addObject:b];
    return na;
}

// `//xtc-flags: skip` — exclude a fixture from the run entirely. For tests
// that exercise a feature no current corpus backend supports (e.g. the XE
// :cloaked formatters: arm64 and xt neither has them). The file stays in
// the tree as documentation/future coverage; it's just not counted.
static BOOL corpusSkipForSource(NSString *rawSource) {
    for (NSString *line in [rawSource componentsSeparatedByString:@"\n"]) {
        NSString *t = [line stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];
        if (![t hasPrefix:@"//xtc-flags:"] && ![t hasPrefix:@"// xtc-flags:"]) continue;
        if ([t rangeOfString:@"skip"].location != NSNotFound) return YES;
    }
    return NO;
}

// `//xtc-flags: expect=sema-error` — a negative test whose CORRECT outcome is
// a sema rejection (e.g. overload_ambiguous deliberately calls an ambiguous
// overload). The verdict is inverted: a sema failure on a targeted backend is
// a pass, and compiling clean (no error) is the failure.
static BOOL corpusExpectsSemaError(NSString *rawSource) {
    for (NSString *line in [rawSource componentsSeparatedByString:@"\n"]) {
        NSString *t = [line stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];
        if (![t hasPrefix:@"//xtc-flags:"] && ![t hasPrefix:@"// xtc-flags:"]) continue;
        if ([t rangeOfString:@"expect=sema-error"].location != NSNotFound) return YES;
    }
    return NO;
}

// `//xtc-link: <fixture>` — a cross-module fixture whose forward-declared
// functions are defined in a companion fixture (e.g. cross_module_caller
// links cross_module_callee). The harness lowers and codegens the named
// companion and links it alongside (clang object on arm64, appended asm on
// xt6502) so the externs resolve and the calls really run. Returns the
// companion's base name (no extension) or nil.
static NSString *corpusLinkCompanion(NSString *rawSource) {
    for (NSString *line in [rawSource componentsSeparatedByString:@"\n"]) {
        NSString *t = [line stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];
        if (![t hasPrefix:@"//xtc-link:"] && ![t hasPrefix:@"// xtc-link:"]) continue;
        NSRange c = [t rangeOfString:@":"];
        NSString *val = [[t substringFromIndex:c.location + 1]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (val.length) return val;
    }
    return nil;
}

// Strip top-level function prototypes (`u8 f(u8 x);`) from a source string.
// Used when merging a `//xtc-link:` companion into one compilation unit: the
// caller forward-declares the companion's functions, but the companion
// supplies real definitions, and xtc sema rejects a prototype coexisting with
// a matching definition. A prototype is a line whose trimmed text is
// `<type> <name>(<args>);` (optionally followed by a // comment) — distinct
// from a definition (`… ) {`), a call (`Stdio.printf(…);` has no leading
// `type name`), or an initialised decl (`u8 a = f(…);` has `=`).
static NSString *stripFunctionPrototypes(NSString *src) {
    static NSRegularExpression *re = nil;
    if (!re) {
        re = [NSRegularExpression regularExpressionWithPattern:
            @"^[A-Za-z_][A-Za-z0-9_@]*\\s+[A-Za-z_][A-Za-z0-9_]*\\s*\\([^){}]*\\)\\s*;"
            options:0 error:NULL];
    }
    NSMutableArray<NSString *> *kept = [NSMutableArray array];
    for (NSString *line in [src componentsSeparatedByString:@"\n"]) {
        NSString *t = [line stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];
        NSRange r = [re rangeOfFirstMatchInString:t options:0
                                            range:NSMakeRange(0, t.length)];
        if (r.location == 0) continue;   // a prototype — drop it
        [kept addObject:line];
    }
    return [kept componentsJoinedByString:@"\n"];
}

static XTCorpusResult *runFixture(NSString *xtPath, NSString *name) {
    XTCorpusResult *r = [[XTCorpusResult alloc] init];
    r.name = name;
    r.prefix = [name componentsSeparatedByString:@"_"].firstObject ?: @"misc";

    NSString *fixBuildDir = [NSString stringWithFormat:@"%@/%@", kBuildDir, name];
    ensureDir(fixBuildDir);
    NSString *logPath = [fixBuildDir stringByAppendingPathComponent:@"log.txt"];

    void (^writeLog)(NSString *) = ^(NSString *msg) {
        [msg writeToFile:logPath atomically:YES
                encoding:NSUTF8StringEncoding error:NULL];
    };
    @autoreleasepool {
        NSString *rawSource = readFile(xtPath);
        if (!rawSource) {
            failBothBackends(r, XTCorpusFailPreproc);
            r.message = @"cannot read source";
            writeLog(@"cannot read source\n");
            return r;
        }

        // --- Per-backend frontend + lowering ---
        // Each backend resolves its OWN platform library, so preproc →
        // sema → lower runs once per backend with the matching include
        // path: the arm64 Stdio (formats to ASCII, emits via `_putc` →
        // stdout) for arm64, the Atari Stdio (screen RAM, dumped by
        // `xts -d`) for xt6502. The arch-neutral lowering itself is the
        // same code; only the imported platform sources differ.
        // Cross-module companion (`//xtc-link: <fixture>`): the named module
        // defines functions this fixture forward-declares and calls. The
        // corpus harness is single-module — and each backend emits a whole-
        // program image, not a relocatable object — so the only sound way to
        // "link" them is to lower the pair as ONE compilation unit. Append
        // the companion's source after this fixture's (forward decl precedes
        // definition, C-style); the calls then resolve intra-module with the
        // matching calling convention on both backends.
        NSString *sourceForFE = rawSource;
        NSString *companion = corpusLinkCompanion(rawSource);
        if (companion) {
            NSString *compPath = [NSString stringWithFormat:@"%@/%@.xc",
                                  kFixtureDir, companion];
            NSString *compSrc = readFile(compPath);
            if (!compSrc) {
                failBothBackends(r, XTCorpusFailPreproc);
                r.message = [NSString stringWithFormat:
                    @"//xtc-link: companion '%@' not found", companion];
                writeLog(r.message);
                return r;
            }
            // Drop the caller's forward decls (the companion defines them)
            // and append the companion's definitions, so the pair lowers as
            // one unit with the calls resolved intra-module.
            sourceForFE = [NSString stringWithFormat:@"%@\n%@",
                           stripFunctionPrototypes(rawSource), compSrc];
        }

        XTIRModule *armMod = nil; XTIRFunction *armEntry = nil;
        XTCorpusOutcome armOutcome = XTCorpusPass; NSString *armMsg = nil;
        BOOL armOracled = NO, xtOracled = NO;
        // arm64 pointers are 8 bytes — the width the arm64 backend actually
        // lays out and loads. This used to say 2, matching the driver's old
        // (wrong) setting: `sizeof(u8@)` reported 2 and a struct with a pointer
        // member got a 2-byte slot that the 64-bit store then overran.
        [XTPointerType setHeapPointerWidth:8];
        [XTType setFloatWidth:4];       // arm64 is IEEE single
        [XTType setFloatIsIEEE:YES];
        [XTStructType setFieldAlignmentCap:8];   // C natural alignment (blewit #5)
        BOOL armFE = corpusFrontend(sourceForFE, xtPath, name,
            @[@"support/arm64/lib", @"support/generic/lib"],
            XTPointerPlacementMain,
            &armMod, &armEntry, &armOutcome, &armMsg);

        // ── xt6502 frontend (3-byte pointers) ─────────────────────
        // The xt6502 backend uses uniform 3-byte pointers [addr-lo,
        // addr-hi, bank] per task #92. Set the heap pointer width
        // to 3 so the type system, parser, lowering, and IR layouts all
        // agree on 3-byte pointer slots. Each target sets the width it
        // really uses; the arm64 frontend above ran with 8.
        [XTPointerType setHeapPointerWidth:3];
        [XTType setFloatWidth:4];       // xt6502 float is IEEE single via the MECH coprocessor
        [XTType setFloatIsIEEE:YES];    // (the driver sets this unconditionally; match it here)
        [XTStructType setFieldAlignmentCap:1];   // xt6502 stays tightly packed (blewit #5)
        XTIRModule *xtMod = nil; XTIRFunction *xtEntry = nil;
        XTCorpusOutcome xtOutcome = XTCorpusPass; NSString *xtMsg = nil;
        BOOL xtFE = corpusFrontend(sourceForFE, xtPath, name,
            @[@"support/xt6502/lib", @"support/generic/lib"],
            XTPointerPlacementHeap,
            &xtMod, &xtEntry, &xtOutcome, &xtMsg);

        // Run each backend's pipeline only if its frontend succeeded;
        // otherwise corpusFrontend already set its outcome/message.
        if (armFE) {
            armOutcome = runArm64Pipeline(armMod, armEntry, fixBuildDir, &armOracled, &armMsg);
        }
        if (xtFE) {
            xtOutcome = runXt6502Pipeline(xtMod, xtEntry, fixBuildDir, &xtOracled, &xtMsg);
        }
        // m68k (Atari ST) — its own honest subprocess (xtc -A 68030),
        // independent of the in-process arm64/xt6502 lowerings.
        XTCorpusOutcome m68kOutcome = XTCorpusPass; NSString *m68kMsg = nil;
        BOOL m68kOracled = NO;
        m68kOutcome = runM68kPipeline(xtPath, fixBuildDir, &m68kOracled, &m68kMsg);

        // arm9 (Zynq Cortex-A9) — its own honest subprocess (xtc -A arm9), run
        // under qemu. Tracked separately like m68k; does not gate the combined
        // arm64+xt6502 verdict.
        XTCorpusOutcome arm9Outcome = XTCorpusPass; NSString *arm9Msg = nil;
        BOOL arm9Oracled = NO;
        arm9Outcome = runArm9Pipeline(xtPath, fixBuildDir, &arm9Oracled, &arm9Msg);

        // x86-64 (System V / musl Linux) — its own honest subprocess
        // (xtc -A x86_64), run over ssh on a Linux host. NotRun when that host
        // is unreachable, which is deliberately neither a pass nor a fail.
        XTCorpusOutcome x86Outcome = XTCorpusPass; NSString *x86Msg = nil;
        BOOL x86Oracled = NO;
        x86Outcome = runX86_64Pipeline(xtPath, fixBuildDir, &x86Oracled, &x86Msg);

        // ── Applicability (expected-to-complete basis) ──────────────────────
        // A fixture applies to every backend EXCEPT those it declares
        // not-applicable (`//xtc-na:` / legacy `target=`). A backend it does NOT
        // apply to is scored as a pass (it was never meant to run); a backend it
        // DOES apply to is scored on its real result — so any failure there is a
        // genuine, visible gap. This is symmetric across all four backends (the
        // old code scored arm64/xt6502 raw and m68k/arm9 scoped, which made the
        // numbers incomparable and hid in-scope failures).
        NSSet<NSString *> *na = corpusNASetForSource(rawSource);
        r.target = corpusTargetForSource(rawSource);   // legacy display only
        BOOL armApp = ![na containsObject:kBackendArm64];
        BOOL xtApp  = ![na containsObject:kBackendXt6502];
        BOOL m68App = ![na containsObject:kBackendM68k];
        BOOL a9App  = ![na containsObject:kBackendArm9];
        BOOL x86App = ![na containsObject:kBackendX86];
        r.arm64Applicable = armApp; r.xt6502Applicable = xtApp;
        r.m68kApplicable = m68App;  r.arm9Applicable = a9App;
        r.x86Applicable = x86App;

        // Negative test (`//xtc-flags: expect=sema-error`): invert each backend's
        // verdict — a sema rejection is the expected pass; compiling clean is the
        // failure. Applied to ALL backends (previously only arm64/xt6502, which
        // wrongly failed m68k/arm9 on every negative test).
        if (corpusExpectsSemaError(rawSource)) {
            // A correct compiler REJECTS the program. In-process (arm64/xt6502)
            // that surfaces as FailSema — or FailParse, when the rule is
            // enforced during parsing (blocks_wb_escape.xc: the wb-escape
            // check lives in parseReturn); via the m68k/arm9 subprocess a
            // rejection is just a non-zero rc → FailCodegen. A program the
            // assembler or linker refuses (undefined_function_refused.xc: a
            // call to a function declared and never defined) is FailAssembleLink.
            // Treat any of these as the expected pass; compiling clean is the
            // failure.
            #define INVERT_SEMA(O, M) do { \
                if ((O) == XTCorpusFailSema || (O) == XTCorpusFailCodegen || (O) == XTCorpusFailParse \
                    || (O) == XTCorpusFailAssembleLink) { (O) = XTCorpusPass; (M) = nil; } \
                else if ((O) == XTCorpusPass) { (O) = XTCorpusFailSema; \
                    (M) = @"expected a sema error, but compiled clean"; } } while (0)
            INVERT_SEMA(armOutcome, armMsg);
            INVERT_SEMA(xtOutcome, xtMsg);
            INVERT_SEMA(m68kOutcome, m68kMsg);
            INVERT_SEMA(arm9Outcome, arm9Msg);
            // NOT x86: a NotRun must stay NotRun. Inverting it would turn "we
            // never ran this" into "expected a sema error, but compiled clean".
            if (x86Outcome != XTCorpusNotRun) INVERT_SEMA(x86Outcome, x86Msg);
            #undef INVERT_SEMA
        }

        // Store the expected-basis outcome per backend: real result where the
        // fixture applies, an automatic pass where it doesn't.
        r.arm64Outcome  = armApp ? armOutcome  : XTCorpusPass;  r.arm64Message  = armMsg;
        r.xt6502Outcome = xtApp  ? xtOutcome   : XTCorpusPass;  r.xt6502Message = xtMsg;
        r.m68kOutcome   = m68App ? m68kOutcome : XTCorpusPass;  r.m68kMessage   = m68kMsg;
        r.arm9Outcome   = a9App  ? arm9Outcome : XTCorpusPass;  r.arm9Message   = arm9Msg;
        // A NotRun stays NotRun even where the fixture doesn't apply — "we never
        // ran it" must never be laundered into "pass".
        r.x86Outcome    = (x86Outcome == XTCorpusNotRun) ? XTCorpusNotRun
                        : (x86App ? x86Outcome : XTCorpusPass);
        r.x86Message    = x86Msg;
        r.oracled = armOracled || xtOracled || m68kOracled || arm9Oracled || x86Oracled;

        // Stage 11a — production subprocess pipeline (xt6502 only). Run when
        // xt6502 applies and its in-process result passed. Not for a negative
        // fixture: its pass is a refusal, and there is nothing to run.
        if (xtApp && xtOutcome == XTCorpusPass && xtFE && !corpusExpectsSemaError(rawSource)) {
            r.subprocessRan = YES;
            NSString *subMsg = nil;
            BOOL subOk = runXt6502SubprocessPipeline(xtPath, fixBuildDir, &subMsg);
            r.xt6502SubprocessPasses = subOk;
            r.xt6502SubprocessMessage = subMsg;
        }

        // Per-arch codegen rejections — only for applicable backends.
        if (armApp && armOutcome == XTCorpusFailCodegen && armMsg.length)
            tallyReason(gArmReasons, gArmExamples, armMsg, name);
        if (xtApp && xtOutcome == XTCorpusFailCodegen && xtMsg.length)
            tallyReason(gXtReasons, gXtExamples, xtMsg, name);
        if (a9App && arm9Outcome == XTCorpusFailCodegen && arm9Msg.length)
            tallyReason(gArm9Reasons, gArm9Examples, arm9Msg, name);

        if (getenv("XTC_ARM9_DEBUG") && r.arm9Outcome != XTCorpusPass)
            fprintf(stderr, "ARM9FAIL\t%s\t%s\n", name.UTF8String, (arm9Msg ?: @"?").UTF8String);
        if (getenv("XTC_FAIL_DEBUG")) {
            // RAW result + applicability per backend. "na" = the fixture opted
            // out (scored pass); anything else with a non-pass is a genuine,
            // in-scope failure.
            #define FAILDUMP(B, APP, O, M) do { if (!(APP)) fprintf(stderr, "NA\t%s\t%s\n", B, name.UTF8String); \
                else if ((O) != XTCorpusPass) fprintf(stderr, "FAIL\t%s\t%s\t%s\n", B, name.UTF8String, ((M) ?: @"?").UTF8String); } while (0)
            FAILDUMP("arm64", armApp, armOutcome, armMsg);
            FAILDUMP("xt6502", xtApp, xtOutcome, xtMsg);
            FAILDUMP("m68k", m68App, m68kOutcome, m68kMsg);
            FAILDUMP("arm9", a9App, arm9Outcome, arm9Msg);
            #undef FAILDUMP
        }
        if (getenv("XTC_RAW_DEBUG")) {
            // RAW per-backend result for ALL backends regardless of applicability
            // (drives the //xtc-na audit: which backends a fixture genuinely fails).
            #define RAWDUMP(B, O, M) fprintf(stderr, "RAW\t%s\t%s\t%s\t%s\n", B, name.UTF8String, \
                (O) == XTCorpusPass ? "P" : "F", ((O) == XTCorpusPass ? @"" : ((M) ?: @"?")).UTF8String)
            RAWDUMP("arm64", armOutcome, armMsg);
            RAWDUMP("xt6502", xtOutcome, xtMsg);
            RAWDUMP("m68k", m68kOutcome, m68kMsg);
            RAWDUMP("arm9", arm9Outcome, arm9Msg);
            #undef RAWDUMP
        }
        if (na.count) writeLog([NSString stringWithFormat:@"na: %@\n",
                                [[na allObjects] componentsJoinedByString:@","]]);

        // Compose the top-level (arm64 ∩ xt6502) verdict from the expected-basis
        // outcomes. Both-pass = Pass; otherwise the worst one wins.
        if (r.arm64Outcome == XTCorpusPass && r.xt6502Outcome == XTCorpusPass) {
            r.outcome = XTCorpusPass;
            r.message = nil;
            writeLog(@"both backends pass\n");
        } else if (r.arm64Outcome == XTCorpusPass) {
            r.outcome = r.xt6502Outcome;
            r.message = [NSString stringWithFormat:@"xt6502: %@", r.xt6502Message ?: @"(no msg)"];
            writeLog([NSString stringWithFormat:@"arm64=pass / xt6502=%@: %@\n",
                      outcomeName(r.xt6502Outcome), r.xt6502Message ?: @""]);
        } else if (r.xt6502Outcome == XTCorpusPass) {
            r.outcome = r.arm64Outcome;
            r.message = [NSString stringWithFormat:@"arm64: %@", r.arm64Message ?: @"(no msg)"];
            writeLog([NSString stringWithFormat:@"xt6502=pass / arm64=%@: %@\n",
                      outcomeName(r.arm64Outcome), r.arm64Message ?: @""]);
        } else {
            // Both failed. Prefer arm64's outcome for the top-level; message
            // carries both.
            r.outcome = r.arm64Outcome;
            r.message = [NSString stringWithFormat:
                @"arm64: %@; xt6502: %@",
                r.arm64Message ?: @"(no msg)", r.xt6502Message ?: @"(no msg)"];
            writeLog([NSString stringWithFormat:
                @"arm64=%@ / xt6502=%@\n",
                outcomeName(r.arm64Outcome), outcomeName(r.xt6502Outcome)]);
        }
    }
    return r;
}

#pragma mark - Report generation

static NSString *renderReport(NSArray<XTCorpusResult *> *results) {
    NSUInteger total = results.count;
    NSCountedSet<NSString *> *byOutcome = [NSCountedSet set];
    NSMutableDictionary<NSString *, NSCountedSet<NSString *> *> *byPrefix =
        [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *examplesByOutcome =
        [NSMutableDictionary dictionary];
    NSUInteger passing = 0;
    for (XTCorpusResult *r in results) {
        NSString *o = outcomeName(r.outcome);
        [byOutcome addObject:o];
        NSCountedSet *prefixSet = byPrefix[r.prefix];
        if (!prefixSet) {
            prefixSet = [NSCountedSet set];
            byPrefix[r.prefix] = prefixSet;
        }
        [prefixSet addObject:o];
        NSMutableArray *list = examplesByOutcome[o];
        if (!list) {
            list = [NSMutableArray array];
            examplesByOutcome[o] = list;
        }
        if (list.count < 3) [list addObject:r.name];
        if (r.outcome == XTCorpusPass) passing++;
    }

    NSMutableString *md = [NSMutableString string];
    [md appendString:@"# new-IR progress\n\n"];
    [md appendString:@"Dual-backend measurement of how far the new-IR pipeline\n"];
    [md appendString:@"gets on the legacy fixture corpus at `tests/fixtures/`.\n"];
    [md appendString:@"Each fixture lowers + verifies once, then runs through\n"];
    [md appendString:@"both backend pipelines: arm64 (clang assemble + execute)\n"];
    [md appendString:@"and xt6502 (xta + xts). Pass = both backends complete\n"];
    [md appendString:@"cleanly AND — when a stdout oracle exists at\n"];
    [md appendString:@"`tests/fixtures/<name>.expected.out` — both produce\n"];
    [md appendString:@"matching stdout. Oracles come from the legacy AST\n"];
    [md appendString:@"codegen pipeline; the generator script is at\n"];
    [md appendString:@"`tests/corpus/generate-oracles.sh`.\n\n"];
    [md appendString:@"Divergences between the two backends are tracked in\n"];
    [md appendString:@"`doc/backend-divergence.md` — they're the leading\n"];
    [md appendString:@"indicator of arm-isms baking into the lowering.\n\n"];

    NSUInteger oracledTotal = 0;
    NSUInteger oracledPassing = 0;
    NSUInteger unoracledTotal = 0;
    NSUInteger unoracledPassing = 0;
    // Expected-to-complete-successfully basis: each backend is scored only over
    // the fixtures that APPLY to it (not excluded via //xtc-na / target=). A
    // backend's number is `passing / applicable`; every applicable non-pass is a
    // genuine, listed failure. Symmetric across all four backends.
    NSUInteger arm64App=0, arm64Pass=0, xtApp_=0, xtPass=0, m68App_=0, m68Pass=0, a9App_=0, a9Pass=0;
    NSUInteger x86App_=0, x86Pass=0, x86NotRun=0;
    NSMutableArray<NSString *> *arm64Fails=[NSMutableArray array], *xtFails=[NSMutableArray array],
                               *m68Fails=[NSMutableArray array],  *a9Fails=[NSMutableArray array],
                               *x86Fails=[NSMutableArray array];
    NSUInteger naArm64=0, naXt=0, naM68=0, naA9=0, naX86=0;
    for (XTCorpusResult *r in results) {
        if (r.oracled) {
            oracledTotal++;
            if (r.outcome == XTCorpusPass) oracledPassing++;
        } else {
            unoracledTotal++;
            if (r.outcome == XTCorpusPass) unoracledPassing++;
        }
        #define TALLY(APP, OUT, MSG, app, pas, fails, nacnt) do { \
            if (r.APP) { app++; if (r.OUT == XTCorpusPass) pas++; \
                else [fails addObject:[NSString stringWithFormat:@"`%@` — %@", r.name, r.MSG ?: @"?"]]; } \
            else nacnt++; } while (0)
        TALLY(arm64Applicable,  arm64Outcome,  arm64Message,  arm64App, arm64Pass, arm64Fails, naArm64);
        TALLY(xt6502Applicable, xt6502Outcome, xt6502Message, xtApp_,   xtPass,    xtFails,    naXt);
        TALLY(m68kApplicable,   m68kOutcome,   m68kMessage,   m68App_,  m68Pass,   m68Fails,   naM68);
        TALLY(arm9Applicable,   arm9Outcome,   arm9Message,   a9App_,   a9Pass,    a9Fails,    naA9);
        #undef TALLY
        // x86-64 is tallied by hand because it has a third state. A NotRun is
        // kept OUT of both numerator and denominator — counting it as a pass
        // would report green for a backend nothing executed, and counting it as
        // a failure would cry wolf when the host is merely offline. It is
        // surfaced on its own line instead.
        if (r.x86Outcome == XTCorpusNotRun) { x86NotRun++; }
        else if (r.x86Applicable) {
            x86App_++;
            if (r.x86Outcome == XTCorpusPass) x86Pass++;
            else [x86Fails addObject:[NSString stringWithFormat:@"`%@` — %@",
                                      r.name, r.x86Message ?: @"?"]];
        } else naX86++;
    }
    NSUInteger arm64Passing = arm64Pass, xt6502Passing = xtPass,
               m68kPassing = m68Pass, arm9Passing = a9Pass;
    NSUInteger onlyArm64 = 0, onlyXt6502 = 0, bothFail = 0;
    for (XTCorpusResult *r in results) {
        if (r.arm64Applicable && r.xt6502Applicable) {
            if (r.arm64Outcome == XTCorpusPass && r.xt6502Outcome != XTCorpusPass) onlyArm64++;
            if (r.xt6502Outcome == XTCorpusPass && r.arm64Outcome != XTCorpusPass) onlyXt6502++;
            if (r.arm64Outcome != XTCorpusPass && r.xt6502Outcome != XTCorpusPass) bothFail++;
        }
    }

    // Stage 11a — production subprocess pipeline stats. Counts fixtures
    // that pass via the in-process xt6502 path AND also pass via the
    // subprocess path. A gap surfaces IR Printer/Parser round-trip bugs,
    // xtcg-6502 backend issues, or xta integration regressions.
    NSUInteger subprocessRan = 0, subprocessPassing = 0;
    for (XTCorpusResult *r in results) {
        if (!r.subprocessRan) continue;
        subprocessRan++;
        if (r.xt6502SubprocessPasses) subprocessPassing++;
    }

    [md appendFormat:@"## Summary\n\n"];
    [md appendFormat:@"- Total fixtures: **%lu**\n", (unsigned long)total];
    [md appendFormat:@"- Both backends passing: **%lu** (%.1f%%)\n",
     (unsigned long)passing,
     total > 0 ? 100.0 * passing / total : 0.0];
    // Per-backend on the expected-to-complete basis: passing / applicable.
    NSString *(^pct)(NSUInteger, NSUInteger) = ^NSString *(NSUInteger p, NSUInteger a) {
        return [NSString stringWithFormat:@"**%lu / %lu** applicable (%.1f%%), %lu n/a",
            (unsigned long)p, (unsigned long)a, a > 0 ? 100.0 * p / a : 100.0,
            (unsigned long)(total - a)]; };
    [md appendFormat:@"\n### Per-backend (expected-to-complete basis)\n\n"];
    [md appendFormat:@"- arm64: %@\n",  pct(arm64Pass, arm64App)];
    [md appendFormat:@"- xt6502: %@\n", pct(xtPass, xtApp_)];
    [md appendFormat:@"- m68k: %@\n",   pct(m68Pass, m68App_)];
    [md appendFormat:@"- arm9: %@\n",   pct(a9Pass, a9App_)];
    if (x86NotRun)
        [md appendFormat:@"- x86_64: **NOT RUN** (%lu fixtures) — host `%@` "
                         @"unreachable. This backend is UNTESTED in this sweep.\n",
                         (unsigned long)x86NotRun, x86Host()];
    else
        [md appendFormat:@"- x86_64: %@\n", pct(x86Pass, x86App_)];
    void (^failList)(NSString *, NSArray<NSString *> *) = ^(NSString *b, NSArray<NSString *> *f) {
        if (f.count == 0) { [md appendFormat:@"\n**%@ genuine failures: none.**\n", b]; return; }
        [md appendFormat:@"\n**%@ genuine failures (%lu):**\n", b, (unsigned long)f.count];
        for (NSString *line in f) [md appendFormat:@"- %@\n", line];
    };
    failList(@"arm64", arm64Fails);
    failList(@"xt6502", xtFails);
    failList(@"m68k", m68Fails);
    failList(@"arm9", a9Fails);
    if (!x86NotRun) failList(@"x86_64", x86Fails);
    [md appendFormat:@"\n"];
    [md appendFormat:@"- arm64-only passing: **%lu** (xt6502 fails)\n",
     (unsigned long)onlyArm64];
    [md appendFormat:@"- xt6502-only passing: **%lu** (arm64 fails)\n",
     (unsigned long)onlyXt6502];
    [md appendFormat:@"- Both failing: **%lu**\n", (unsigned long)bothFail];
    [md appendFormat:@"- Oracled: **%lu** of %lu (%lu passing both backends)\n",
     (unsigned long)oracledTotal, (unsigned long)total,
     (unsigned long)oracledPassing];
    [md appendFormat:@"- Un-oracled: **%lu** (%lu passing on rc==0 alone)\n",
     (unsigned long)unoracledTotal, (unsigned long)unoracledPassing];
    [md appendFormat:@"- xt6502 via production subprocess pipeline: **%lu / %lu** "
                      @"(of fixtures that pass in-process — gaps reveal "
                      @"round-trip / xtcg-6502 / xta bugs)\n\n",
     (unsigned long)subprocessPassing, (unsigned long)subprocessRan];

    // ── By outcome ──────────────────────────────────────────
    // The top-level table groups by the combined outcome (worst of
    // the two backends). The per-backend split appears as the
    // arm64 / xt6502 sub-columns.
    NSCountedSet<NSString *> *armByOutcome = [NSCountedSet set];
    NSCountedSet<NSString *> *xtByOutcome = [NSCountedSet set];
    for (XTCorpusResult *r in results) {
        [armByOutcome addObject:outcomeName(r.arm64Outcome)];
        [xtByOutcome addObject:outcomeName(r.xt6502Outcome)];
    }
    [md appendString:@"## By failure stage\n\n"];
    [md appendString:@"| Stage | Combined | arm64 | xt6502 | Examples |\n"];
    [md appendString:@"|-------|---------:|------:|-------:|----------|\n"];
    NSArray<NSString *> *orderedStages = @[
        @"pass", @"preproc", @"parse", @"sema", @"lower", @"verify",
        @"codegen", @"assemble_link", @"runtime", @"timeout",
        @"no_functions"];
    for (NSString *stage in orderedStages) {
        NSUInteger c = [byOutcome countForObject:stage];
        NSUInteger ac = [armByOutcome countForObject:stage];
        NSUInteger xc = [xtByOutcome countForObject:stage];
        if (c == 0 && ac == 0 && xc == 0) continue;
        NSArray *ex = examplesByOutcome[stage] ?: @[];
        [md appendFormat:@"| %@ | %lu | %lu | %lu | %@ |\n",
         stage, (unsigned long)c, (unsigned long)ac, (unsigned long)xc,
         [ex componentsJoinedByString:@", "]];
    }
    [md appendString:@"\n"];

    // ── By prefix ───────────────────────────────────────────
    [md appendString:@"## By fixture-name prefix\n\n"];
    [md appendString:@"Fixture-name prefix is a coarse proxy for which language\n"];
    [md appendString:@"feature the fixture exercises. The columns name the most\n"];
    [md appendString:@"common fail-stages — empty cells mean zero fixtures with\n"];
    [md appendString:@"that prefix landed in that stage.\n\n"];
    [md appendString:@"| Prefix | Total | pass | lower | verify | codegen | runtime | other |\n"];
    [md appendString:@"|--------|------:|-----:|------:|-------:|--------:|--------:|------:|\n"];
    NSArray<NSString *> *sortedPrefixes = [byPrefix.allKeys sortedArrayUsingComparator:
        ^NSComparisonResult(NSString *a, NSString *b) {
            NSUInteger ca = 0, cb = 0;
            for (NSString *s in byPrefix[a]) ca += [byPrefix[a] countForObject:s];
            for (NSString *s in byPrefix[b]) cb += [byPrefix[b] countForObject:s];
            if (ca != cb) return ca > cb ? NSOrderedAscending : NSOrderedDescending;
            return [a compare:b];
        }];
    for (NSString *prefix in sortedPrefixes) {
        NSCountedSet *s = byPrefix[prefix];
        NSUInteger pTotal = 0;
        for (NSString *o in s) pTotal += [s countForObject:o];
        NSUInteger pPass     = [s countForObject:@"pass"];
        NSUInteger pLower    = [s countForObject:@"lower"];
        NSUInteger pVerify   = [s countForObject:@"verify"];
        NSUInteger pCodegen  = [s countForObject:@"codegen"];
        NSUInteger pRuntime  = [s countForObject:@"runtime"];
        NSUInteger pOther    = pTotal - pPass - pLower - pVerify - pCodegen - pRuntime;
        NSString *(^cell)(NSUInteger) = ^NSString *(NSUInteger n) {
            return n == 0 ? @"·" : [NSString stringWithFormat:@"%lu", (unsigned long)n];
        };
        [md appendFormat:@"| %@ | %lu | %@ | %@ | %@ | %@ | %@ | %@ |\n",
         prefix, (unsigned long)pTotal,
         cell(pPass), cell(pLower), cell(pVerify),
         cell(pCodegen), cell(pRuntime), cell(pOther)];
    }
    [md appendString:@"\n"];

    // ── Top categories by fixture count ──────────────────────
    [md appendString:@"## Top categories to extend next\n\n"];
    NSArray<NSString *> *top = [sortedPrefixes subarrayWithRange:
        NSMakeRange(0, MIN(3u, (unsigned)sortedPrefixes.count))];
    NSDictionary<NSString *, NSString *> *expandHint = @{
        @"arc":      @"ARC strong-slot semantics — lowering emits Retain / Release at the right sites; the arm64 backend (task #18) needs to lower those ops.",
        @"class":    @"Class declarations + method dispatch — instance layouts, vtable symbols, and Call-shaped method dispatch land in task #17; VTblDispatch awaits backend coverage in task #18.",
        @"float":    @"FP arithmetic — lowering rejects floats today; once it lowers FAdd/FSub/FMul/FDiv, the 6502 backend lowers them to runtime helper calls per IR-SPEC §6.2a.",
        @"f32":      @"F32 lowering — see `float`.",
        @"f64":      @"F64 lowering — see `float`.",
        @"double":   @"Double-precision FP — same path as `float`.",
        @"printf":   @"Strings + variadic calls — needs string literals (Sym(stringlit) ops in the symbol table) and variadic-arg handling.",
        @"stdio":    @"Stdio library calls — depends on `printf` plus class-method dispatch.",
        @"new":      @"Heap allocation — `new T()` now routes to a per-class `_xtc_new_<T>` runtime helper; the helper itself lands in the runtime support task.",
        @"delete":   @"Heap deallocation — depends on `new` plus class-destructor dispatch.",
        @"pointer":  @"Pointer types — needs Ptr(T, window) in the lowering's type mapping (currently rejected).",
        @"addrof":   @"AddrOf — needs the lowering to pin a local at function entry when it sees `&x`.",
        @"for":      @"C-style for loop — currently rejected by the lowering's statement dispatch.",
        @"forin":    @"for-in over arrays — depends on the array type lowering.",
        @"switch":   @"switch / case — needs the Switch terminator and a multi-target lowering.",
        @"asm":      @"Inline asm — needs the Asm op with binding / clobber lowering.",
        @"banked":   @"Banking annotations — needs CallBanked emission and the xt code-bank symbol metadata.",
        @"cloaked":  @"Cloaked calling convention — needs CallCloaked emission and the $B0-$BF arg-staging ABI.",
        @"tuple":    @"Multi-return / tuple-assign — needs the lowering to return Agg(L) and the caller to AggExtract.",
        @"gfx":      @"Graphics library — depends on the class-method dispatch chain.",
        @"string":   @"String operations — depends on `printf` plus pointer types.",
        @"foundation": @"Foundation library — depends on class-method dispatch + various unsupported AST kinds.",
        @"heap":     @"Heap stress tests — depend on `new`/`delete` plus the runtime allocator helpers.",
    };
    for (NSString *prefix in top) {
        NSString *hint = expandHint[prefix];
        if (!hint) hint = @"Mixed bag — open the per-fixture logs under build/corpus/<name>/ to triage.";
        NSCountedSet *s = byPrefix[prefix];
        NSUInteger pTotal = 0, pPass = 0;
        for (NSString *o in s) {
            NSUInteger c = [s countForObject:o];
            pTotal += c;
            if ([o isEqualToString:@"pass"]) pPass = c;
        }
        [md appendFormat:@"- **`%@_*` (%lu fixtures, %lu passing).** %@\n",
         prefix, (unsigned long)pTotal, (unsigned long)pPass, hint];
    }
    [md appendString:@"\n"];

    [md appendString:@"## Notes\n\n"];
    [md appendString:@"- Per-fixture artefacts (asm, stub, binary, captured\n"];
    [md appendString:@"  stdout/stderr, failure log) land in `build/corpus/<name>/`\n"];
    [md appendString:@"  for individual-failure triage. The `log.txt` in each\n"];
    [md appendString:@"  directory has the first error message the pipeline\n"];
    [md appendString:@"  emitted, which is usually enough to recognise the\n"];
    [md appendString:@"  category.\n"];
    [md appendString:@"- The sweep stub generates a trivial C `main` that calls\n"];
    [md appendString:@"  the fixture's first function-with-body with zero args.\n"];
    [md appendString:@"  A fixture whose entry expects specific argument values\n"];
    [md appendString:@"  may still hit a `runtime` failure even after the\n"];
    [md appendString:@"  lowering supports the relevant constructs — counting\n"];
    [md appendString:@"  it as a pass requires the oracle work tracked above.\n"];
    [md appendString:@"- Tag = the most recent `phase-NNN` commit that\n"];
    [md appendString:@"  represents the toolchain state at this sweep.\n\n"];

    // Final line: timestamp + phase tag pair. Read the tag from the
    // CORPUS_TAG environment variable when set (the Makefile target
    // can wire this up later); fall back to "(untagged)" for an
    // ad-hoc sweep run by hand.
    const char *tagEnv = getenv("CORPUS_TAG");
    NSString *tag = tagEnv ? [NSString stringWithUTF8String:tagEnv] : @"(untagged)";
    NSDateFormatter *dfmt = [[NSDateFormatter alloc] init];
    dfmt.dateFormat = @"yyyy-MM-dd";
    dfmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    dfmt.timeZone = [NSTimeZone timeZoneWithName:@"UTC"];
    NSString *today = [dfmt stringFromDate:[NSDate date]];
    [md appendFormat:@"Last sweep: %@ — %@\n", tag, today];

    return md;
}

#pragma mark - Divergence report

static NSString *renderDivergenceReport(NSArray<XTCorpusResult *> *results) {
    NSMutableArray<XTCorpusResult *> *armOnly = [NSMutableArray array];
    NSMutableArray<XTCorpusResult *> *xtOnly = [NSMutableArray array];
    for (XTCorpusResult *r in results) {
        // Only fixtures expected to work on BOTH backends can diverge.
        // An arch-pinned fixture (target=arm64 / target=xt6502 — gr.8
        // graphics, inline 6502 asm) is, by definition, not expected to
        // run on the other backend, so its "failure" there is not a
        // compatibility gap and must not pollute this table.
        if (r.target != XTCorpusTargetBoth) continue;
        BOOL aPass = (r.arm64Outcome == XTCorpusPass);
        BOOL xPass = (r.xt6502Outcome == XTCorpusPass);
        if (aPass && !xPass) [armOnly addObject:r];
        else if (xPass && !aPass) [xtOnly addObject:r];
    }

    NSMutableString *md = [NSMutableString string];
    [md appendString:@"# Backend divergence\n\n"];
    [md appendString:@"Fixtures where the two backends disagree on outcome.\n"];
    [md appendString:@"Each row is a fixture whose arm64 binary passes but\n"];
    [md appendString:@"xt6502's doesn't (or vice versa) — a signal that an\n"];
    [md appendString:@"arm-ism may be baking into the lowering, or that one\n"];
    [md appendString:@"backend has a coverage gap the other doesn't.\n\n"];
    [md appendString:@"This file is **regenerated by every `make corpus`** —\n"];
    [md appendString:@"don't edit by hand; trace causes via the per-fixture\n"];
    [md appendString:@"artefacts under `build/corpus/<name>/`.\n\n"];
    [md appendFormat:@"## arm64 passes, xt6502 fails (%lu)\n\n",
     (unsigned long)armOnly.count];
    if (armOnly.count == 0) {
        [md appendString:@"None.\n\n"];
    } else {
        [md appendString:@"| Fixture | xt6502 outcome | xt6502 message |\n"];
        [md appendString:@"|---------|----------------|----------------|\n"];
        // Group similar messages so the table doesn't sprawl.
        for (XTCorpusResult *r in armOnly) {
            NSString *msg = r.xt6502Message ?: @"";
            if (msg.length > 80) msg = [[msg substringToIndex:77] stringByAppendingString:@"..."];
            [md appendFormat:@"| %@ | %@ | %@ |\n",
             r.name, outcomeName(r.xt6502Outcome), msg];
        }
        [md appendString:@"\n"];
    }
    [md appendFormat:@"## xt6502 passes, arm64 fails (%lu)\n\n",
     (unsigned long)xtOnly.count];
    if (xtOnly.count == 0) {
        [md appendString:@"None.\n\n"];
    } else {
        [md appendString:@"| Fixture | arm64 outcome | arm64 message |\n"];
        [md appendString:@"|---------|---------------|---------------|\n"];
        for (XTCorpusResult *r in xtOnly) {
            NSString *msg = r.arm64Message ?: @"";
            if (msg.length > 80) msg = [[msg substringToIndex:77] stringByAppendingString:@"..."];
            [md appendFormat:@"| %@ | %@ | %@ |\n",
             r.name, outcomeName(r.arm64Outcome), msg];
        }
        [md appendString:@"\n"];
    }

    // Stage 11a — subprocess gaps. Fixtures that pass in-process but
    // FAIL via the production subprocess pipeline. Each entry is a
    // real bug in Printer/Parser round-trip, xtcg-6502 codegen, or the
    // xta integration. Empty list = production path is on parity with
    // in-process.
    NSMutableArray<XTCorpusResult *> *subprocessGap = [NSMutableArray array];
    for (XTCorpusResult *r in results) {
        if (r.subprocessRan && !r.xt6502SubprocessPasses) {
            [subprocessGap addObject:r];
        }
    }
    [md appendFormat:@"## In-process passes, subprocess fails (xt6502, %lu)\n\n",
     (unsigned long)subprocessGap.count];
    [md appendString:@"Fixtures the in-process xt6502 pipeline gets right but the\n"];
    [md appendString:@"production `xtc -fnew-ir -m xt` subprocess chain (xtc-fe →\n"];
    [md appendString:@"xtcg-6502 → xta → xts) doesn't. Each row is a Printer/Parser\n"];
    [md appendString:@"round-trip bug, an xtcg-6502 codegen divergence, or a\n"];
    [md appendString:@"production-only assembly gap.\n\n"];
    if (subprocessGap.count == 0) {
        [md appendString:@"None. Production path on parity with in-process.\n\n"];
    } else {
        [md appendString:@"| Fixture | subprocess message |\n"];
        [md appendString:@"|---------|--------------------|\n"];
        for (XTCorpusResult *r in subprocessGap) {
            NSString *msg = r.xt6502SubprocessMessage ?: @"";
            if (msg.length > 80) msg = [[msg substringToIndex:77] stringByAppendingString:@"..."];
            [md appendFormat:@"| %@ | %@ |\n", r.name, msg];
        }
        [md appendString:@"\n"];
    }
    return md;
}

#pragma mark - main

int main(int argc, const char *argv[]) {
    // Line-buffer stdout so `make corpus | tail` (a pipe, not a tty) streams the
    // per-fixture progress live instead of dumping everything at the end.
    setvbuf(stdout, NULL, _IOLBF, 0);
    // If the sweep is interrupted (Ctrl-C, `kill`, hang-up, session reset) take
    // any in-flight children — chiefly a still-running qemu — down with us,
    // instead of orphaning them to PID 1 to spin forever.
    installChildReaper();
    @autoreleasepool {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSError *err = nil;
        NSArray *all = [fm contentsOfDirectoryAtPath:kFixtureDir error:&err];
        if (!all) {
            fprintf(stderr, "xtc_corpus_sweep: cannot read %s\n", kFixtureDir.UTF8String);
            return 1;
        }
        // Optional filter: $XTC_CORPUS_FILTER restricts the sweep to
        // fixtures whose name contains the substring. Useful during
        // dev for fast iteration (smoke-test ~10 instead of the
        // full ~300). Per the workflow memory, full sweeps run
        // just before commit; dev cycles use the filter.
        const char *filterEnv = getenv("XTC_CORPUS_FILTER");
        NSString *filter = filterEnv ? [NSString stringWithUTF8String:filterEnv] : nil;

        // SHARDING. The sweep is a serial loop and most of its time is spent
        // RUNNING fixtures (the 6502 simulator, native binaries), so it
        // parallelises cleanly by splitting the fixture list — which is what
        // takes `make corpus` from half an hour to a few minutes. Each shard
        // gets its own build root because libxt.a is built into it once.
        //
        // A sharded run prints its summary and writes NO report, exactly as a
        // filtered run does: a report covering a twelfth of the corpus, at the
        // path the whole-corpus report lives, would be worse than none.
        NSUInteger shardI = 0, shardN = 1;
        const char *sI = getenv("XTC_CORPUS_SHARD_I");
        const char *sN = getenv("XTC_CORPUS_SHARD_N");
        if (sI && sN) {
            long i = atol(sI), n = atol(sN);
            if (n > 0 && i >= 0 && i < n) { shardI = (NSUInteger)i; shardN = (NSUInteger)n; }
        }
        if (shardN > 1) {
            kBuildDir = [NSString stringWithFormat:@"build/corpus.%lu",
                                                   (unsigned long)shardI];
        }

        // Previously-deferred fixtures (the 3 Foundation cases that
        // tipped ~1 byte over the flat 31 KB screen guard once real
        // protocol dispatch landed in #58). Code banking (task #60) lifts
        // that ceiling, so they're RE-ENABLED — the sweep now measures
        // them through the xt banked harness like everything else.
        NSSet<NSString *> *deferred = [NSSet set];

        NSMutableArray<NSString *> *fixtures = [NSMutableArray array];
        NSUInteger deferredCount = 0;
        for (NSString *n in all) {
            if (![n hasSuffix:@".xc"]) continue;
            if (filter && [n rangeOfString:filter].location == NSNotFound) continue;
            if ([deferred containsObject:n]) { deferredCount++; continue; }
            [fixtures addObject:n];
        }
        if (deferredCount > 0) {
            fprintf(stderr, "deferred (banking-blocked, see KNOWN-ISSUES): %lu fixtures\n",
                    (unsigned long)deferredCount);
        }
        [fixtures sortUsingSelector:@selector(compare:)];
        if (shardN > 1) {
            NSMutableArray<NSString *> *mine = [NSMutableArray array];
            for (NSUInteger i = shardI; i < fixtures.count; i += shardN)
                [mine addObject:fixtures[i]];
            fixtures = mine;
            fprintf(stderr, "shard %lu/%lu -> %lu fixtures\n",
                    (unsigned long)shardI, (unsigned long)shardN,
                    (unsigned long)fixtures.count);
        }
        if (filter) {
            fprintf(stderr, "filter '%s' → %lu fixtures\n",
                    filter.UTF8String, (unsigned long)fixtures.count);
        }

        ensureDir(kBuildDir);

        gLowerReasons = [NSCountedSet set];
        gXtReasons = [NSCountedSet set];
        gArmReasons = [NSCountedSet set];
        gArm9Reasons = [NSCountedSet set];
        gLowerExamples = [NSMutableDictionary dictionary];
        gXtExamples = [NSMutableDictionary dictionary];
        gArmExamples = [NSMutableDictionary dictionary];
        gArm9Examples = [NSMutableDictionary dictionary];

        NSMutableArray<XTCorpusResult *> *results = [NSMutableArray array];
        NSUInteger total = fixtures.count;
        NSUInteger idx = 0;
        NSUInteger skipped = 0;
        for (NSString *file in fixtures) {
            idx++;
            NSString *name = [file stringByDeletingPathExtension];
            NSString *path = [kFixtureDir stringByAppendingPathComponent:file];
            // `//xtc-flags: skip` — drop the fixture from the run entirely
            // (not counted in any total). Kept in the tree for documentation.
            NSString *peek = readFile(path);
            if (peek && corpusSkipForSource(peek)) {
                skipped++;
                fprintf(stderr, "[%4lu/%lu] %-40s skipped\n",
                        (unsigned long)idx, (unsigned long)total, name.UTF8String);
                continue;
            }
            XTCorpusResult *r = runFixture(path, name);
            [results addObject:r];
            fprintf(stderr, "[%4lu/%lu] %-40s %s%s\n",
                    (unsigned long)idx, (unsigned long)total,
                    name.UTF8String,
                    outcomeName(r.outcome).UTF8String,
                    r.message.length > 0
                        ? [NSString stringWithFormat:@"  -- %@", r.message].UTF8String
                        : "");
        }

        // Render the report. Filtered runs are smoke tests and SHARDED runs
        // each see a slice — never overwrite the full-sweep deliverable with a
        // partial result. (The guard used to name only the filter; a shard
        // would have written a twelfth of the corpus to the whole-corpus
        // report path, which is the exact hazard this comment warns about.)
        if (filter || shardN > 1) {
            fprintf(stderr, "%s — skipping write of %s\n",
                    filter ? "filter active" : "sharded run",
                    kReportPath.UTF8String);
        } else {
            NSString *md = renderReport(results);
            ensureDir([kReportPath stringByDeletingLastPathComponent]);
            [md writeToFile:kReportPath atomically:YES
                   encoding:NSUTF8StringEncoding error:&err];
            if (err) {
                fprintf(stderr, "xtc_corpus_sweep: cannot write %s: %s\n",
                        kReportPath.UTF8String, err.localizedDescription.UTF8String);
                return 1;
            }
            NSString *div = renderDivergenceReport(results);
            [div writeToFile:kDivergencePath atomically:YES
                    encoding:NSUTF8StringEncoding error:&err];
            if (err) {
                fprintf(stderr, "xtc_corpus_sweep: cannot write %s: %s\n",
                        kDivergencePath.UTF8String, err.localizedDescription.UTF8String);
                return 1;
            }
            // Abandon-reason tally files (rewritten each full sweep).
            writeReasonFile(@"doc/abandon-reasons.lower.txt",
                            @"Lowering abandon reasons (arch-neutral)",
                            gLowerReasons, gLowerExamples);
            writeReasonFile(@"doc/abandon-reasons.xt6502.txt",
                            @"xt6502 codegen rejections", gXtReasons, gXtExamples);
            writeReasonFile(@"doc/abandon-reasons.arm64.txt",
                            @"arm64 codegen rejections", gArmReasons, gArmExamples);
            writeReasonFile(@"doc/abandon-reasons.arm9.txt",
                            @"arm9 codegen/link rejections", gArm9Reasons, gArm9Examples);
        }

        NSUInteger passCount = 0;
        for (XTCorpusResult *r in results) if (r.outcome == XTCorpusPass) passCount++;
        NSUInteger ranTotal = results.count;   // excludes //xtc-flags: skip fixtures
        fprintf(stderr, "\n=== corpus sweep: %lu / %lu pass (%.1f%%)%s ===\n",
                (unsigned long)passCount, (unsigned long)ranTotal,
                ranTotal ? 100.0 * passCount / (double)ranTotal : 0.0,
                skipped ? [NSString stringWithFormat:@", %lu skipped",
                          (unsigned long)skipped].UTF8String : "");
        // Repeat the x86 coverage state at the END: the banner printed at probe
        // time has scrolled past hundreds of fixture lines by now, and a coverage
        // hole nobody sees is the same as no warning at all.
        NSUInteger x86NotRunN = 0, x86FailN = 0, x86PassN = 0;
        for (XTCorpusResult *r in results) {
            if (r.x86Outcome == XTCorpusNotRun)      x86NotRunN++;
            else if (!r.x86Applicable)               continue;
            else if (r.x86Outcome == XTCorpusPass)   x86PassN++;
            else                                     x86FailN++;
        }
        if (x86NotRunN) {
            fprintf(stderr,
              "!! x86_64: NOT RUN (%lu fixtures) — host '%s' unreachable.\n"
              "!!         That backend is UNTESTED above; the pass rate does\n"
              "!!         NOT cover it. Bring the host up or set XTC_X86_HOST.\n",
              (unsigned long)x86NotRunN, x86Host().UTF8String);
        } else {
            fprintf(stderr, "x86_64: %lu / %lu pass\n",
                    (unsigned long)x86PassN, (unsigned long)(x86PassN + x86FailN));
        }
        if (!filter && shardN == 1) {
            fprintf(stderr, "report written to %s\n", kReportPath.UTF8String);
        }

        // Top abandon reasons — the priority signal for what to build
        // next. Lowering reasons first (arch-neutral, the bulk), then
        // any per-arch backend rejections.
        void (^printTop)(NSString *, NSCountedSet *) = ^(NSString *label, NSCountedSet *cs) {
            if (cs.count == 0) return;
            NSArray *top = [cs.allObjects sortedArrayUsingComparator:
                ^NSComparisonResult(NSString *a, NSString *b) {
                    NSUInteger ca = [cs countForObject:a], cb = [cs countForObject:b];
                    return ca < cb ? NSOrderedDescending : (ca > cb ? NSOrderedAscending : [a compare:b]);
                }];
            fprintf(stderr, "\n=== top abandon reasons — %s ===\n", label.UTF8String);
            NSUInteger shown = 0;
            for (NSString *cat in top) {
                if (shown++ >= 5) break;
                fprintf(stderr, "  %4lu  %s\n",
                        (unsigned long)[cs countForObject:cat], cat.UTF8String);
            }
        };
        printTop(@"lowering (arch-neutral)", gLowerReasons);
        printTop(@"xt6502 codegen", gXtReasons);
        printTop(@"arm64 codegen", gArmReasons);
        printTop(@"arm9 codegen/link", gArm9Reasons);
        if (!filter) {
            fprintf(stderr, "full tally → doc/abandon-reasons.{lower,xt6502,arm64,arm9}.txt\n");
        }
    }
    return 0;
}
