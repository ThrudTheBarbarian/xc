// XTTarget.m — see the header.
#import "XTTarget.h"

@interface XTTarget ()
@property(nonatomic, readwrite, copy) NSString* name;
@property(nonatomic, readwrite, copy) NSArray<NSString*>* aliases;
@property(nonatomic, readwrite, copy) NSString* cpu;
@property(nonatomic, readwrite) NSInteger cpuVariant;
@property(nonatomic, readwrite, copy) NSString* os;
@property(nonatomic, readwrite, copy, nullable) NSString* env;
@property(nonatomic, readwrite, copy) NSString* libc;
@property(nonatomic, readwrite, copy) NSString* legacy;
@property(nonatomic, readwrite, copy) NSString* backend;
@property(nonatomic, readwrite, copy) NSString* codegen;
@property(nonatomic, readwrite, copy) NSArray<NSString*>* supportChain;
@property(nonatomic, readwrite, copy, nullable) NSString* platformLayer;
@property(nonatomic, readwrite, copy) NSString* abi;
@property(nonatomic, readwrite) BOOL lseAtomics;
@property(nonatomic, readwrite, copy, nullable) NSString* appleSdk;
@property(nonatomic, readwrite, copy) NSArray<NSString*>* parKernels;
@property(nonatomic, readwrite, copy, nullable) NSString* matmul;
@property(nonatomic, readwrite, copy) NSString* exeFormat;
@property(nonatomic, readwrite, copy, nullable) NSString* crt;
@property(nonatomic, readwrite, copy, nullable) NSString* runtime;
@property(nonatomic, readwrite, copy, nullable) NSString* interp;
@property(nonatomic, readwrite, copy) NSArray<NSString*>* needed;
@property(nonatomic, readwrite, copy) NSString* bundlePlatform;
@property(nonatomic, readwrite, copy) NSArray<NSString*>* libExts;
@property(nonatomic, readwrite, copy) NSString* checkedRuntime;
@end

@implementation XTTarget

// A row: name, cpu, cpu variant, os, env (or ""), libc, legacy spelling, then
// its aliases separated by spaces — the port's TargetRow.make.
static XTTarget* row(NSString* name, NSString* cpu, NSInteger variant, NSString* os, NSString* env,
                     NSString* libc, NSString* legacy, NSString* backend, NSString* codegen, NSString* chain, NSString* layer, NSString* abi, BOOL lse, NSString* sdk, NSString* kernels, NSString* matmul, NSString* fmt, NSString* crt, NSString* rt, NSString* interp, NSString* needed, NSString* bundle, NSString* exts, NSString* checked, NSString* aliases)
    {
    XTTarget* r = [[XTTarget alloc] init];
    r.name = name;
    r.cpu = cpu;
    r.cpuVariant = variant;
    r.os = os;
    r.env = env.length ? env : nil;
    r.libc = libc;
    r.legacy = legacy;
    r.backend = backend;
    r.codegen = codegen;
    NSMutableArray<NSString*>* ch = [NSMutableArray array];
    for (NSString* c in [chain componentsSeparatedByString:@" "])
        if (c.length)
            [ch addObject:c];
    r.supportChain = ch;
    r.platformLayer = layer.length ? layer : nil;
    r.abi = abi;
    r.lseAtomics = lse;
    r.appleSdk = sdk.length ? sdk : nil;
    NSMutableArray<NSString*>* ks = [NSMutableArray array];
    for (NSString* w in [kernels componentsSeparatedByString:@" "])
        if (w.length)
            [ks addObject:w];
    r.parKernels = ks;
    r.matmul = matmul.length ? matmul : nil;
    r.exeFormat = fmt;
    r.crt = crt.length ? crt : nil;
    r.runtime = rt.length ? rt : nil;
    r.interp = interp.length ? interp : nil;
    NSMutableArray<NSString*>* nd = [NSMutableArray array];
    for (NSString* w in [needed componentsSeparatedByString:@" "])
        if (w.length)
            [nd addObject:w];
    r.needed = nd;
    r.bundlePlatform = bundle;
    r.libExts = [exts componentsSeparatedByString:@" "];
    r.checkedRuntime = checked;
    NSMutableArray<NSString*>* al = [NSMutableArray array];
    for (NSString* a in [aliases componentsSeparatedByString:@" "])
        if (a.length)
            [al addObject:a];
    r.aliases = al;
    return r;
    }

+ (NSArray<XTTarget*>*)rows
    {
    static NSArray<XTTarget*>* t;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        t = @[
            row(@"arm64-macos", @"arm64", 0, @"macos", @"", @"darwin", @"arm64", @"arm64", @"arm64", @"arm64", @"", @"darwin64", YES, @"macosx", @"metal", @"sme", @"macho", @"crt-macos.s", @"rt-macos.s", @"", @"", @"macos-arm64", @"dylib so", @"rt-checked-macos.s",
                @"arm64 aarch64-apple-darwin arm64-apple-macos arm64-apple-darwin"),
            row(@"arm64-ios", @"arm64", 0, @"ios", @"", @"darwin", @"ios", @"arm64", @"arm64", @"ios arm64", @"ios", @"darwin64", YES, @"iphoneos", @"", @"", @"macho", @"crt-macos.s", @"rt-macos.s", @"", @"", @"ios-arm64", @"dylib so", @"rt-checked-macos.s",
                @"ios arm64-apple-ios"),
            row(@"arm64-ios-sim", @"arm64", 0, @"ios", @"simulator", @"darwin", @"ios-sim", @"arm64", @"arm64", @"ios arm64", @"ios-sim", @"darwin64", YES, @"iphonesimulator", @"", @"", @"macho", @"crt-macos.s", @"rt-macos.s", @"", @"", @"ios-arm64", @"dylib so", @"rt-checked-macos.s",
                @"ios-sim arm64-apple-ios-simulator"),
            row(@"arm64-android", @"arm64", 0, @"android", @"", @"bionic", @"android", @"arm64", @"arm64", @"arm64", @"android", @"aapcs64", NO, @"", @"spirv", @"", @"elf-pie", @"crt-android.s", @"rt-android.s", @"/system/bin/linker64", @"libc.so libm.so libdl.so", @"android-arm64", @"so", @"",
                @"android aarch64-linux-android"),
            row(@"arm64-linux", @"arm64", 0, @"linux", @"", @"glibc", @"arm64-linux", @"arm64", @"arm64", @"arm64", @"linux-arm64", @"aapcs64", NO, @"", @"spirv", @"", @"elf-pie", @"crt-glibc.s", @"rt-glibc.s", @"/lib/ld-linux-aarch64.so.1", @"libc.so.6 libm.so.6", @"linux-arm64", @"so", @"",
                @"aarch64-linux-gnu arm64-linux-gnu aarch64-unknown-linux-gnu"),
            row(@"x86_64-linux", @"x86_64", 0, @"linux", @"", @"glibc", @"x86_64", @"x86_64", @"x86_64", @"x86_64", @"", @"sysv", NO, @"", @"ptx spirv", @"x86", @"elf-dyn", @"", @"", @"", @"", @"linux-x86_64", @"so dylib", @"",
                @"x86_64 x86-64 amd64 x86_64-linux-gnu x86_64-pc-linux-gnu"),
            row(@"x86_64-linux-musl", @"x86_64", 0, @"linux", @"", @"musl", @"x86_64", @"x86_64", @"x86_64", @"x86_64", @"", @"sysv", NO, @"", @"", @"x86", @"elf-static", @"", @"", @"", @"", @"linux-x86_64", @"so dylib", @"",
                @"x86_64-pc-linux-musl"),
            row(@"x86_64-windows", @"x86_64", 0, @"windows", @"", @"msvcrt", @"win64", @"win64", @"win64", @"win64 x86_64", @"", @"win64", NO, @"", @"ptx spirv", @"", @"pe", @"", @"", @"", @"", @"windows-x86_64", @"dll dll.a a", @"",
                @"win64 windows x86_64-w64-mingw32 x86_64-w64-windows-gnu x86_64-pc-windows-gnu"),
            row(@"armv7-xtos", @"armv7", 0, @"xtos", @"", @"xtos", @"arm9", @"arm9", @"arm9", @"arm9", @"", @"aapcs-vfp", NO, @"", @"", @"", @"elf32-dyn", @"", @"", @"", @"", @"xtos-arm9", @"so dylib", @"",
                @"arm9 armv7 armv7-a cortex-a9"),
            row(@"wasm32-web", @"wasm32", 0, @"web", @"", @"none", @"wasm32", @"wasm32", @"wasm32", @"wasm32", @"", @"wasm", NO, @"", @"wgsl", @"", @"wasm", @"", @"", @"", @"", @"wasm32", @"wasm", @"",
                @"wasm32 wasm wasm32-unknown-unknown"),
            row(@"m68k-tos", @"m68k", 68000, @"tos", @"", @"none", @"m68k", @"atarist", @"68k", @"atarist", @"", @"m68k", NO, @"", @"", @"", @"prg", @"", @"", @"", @"", @"macos-arm64", @"so dylib", @"",
                @"m68k 68000 atarist m68k-atari-tos"),
            row(@"m68030-tos", @"m68k", 68030, @"tos", @"", @"none", @"m68k", @"atarist", @"68k", @"atarist", @"", @"m68k", NO, @"", @"", @"", @"prg", @"", @"", @"", @"", @"macos-arm64", @"so dylib", @"",
                @"68030"),
            row(@"6502-xt", @"6502", 0, @"xt", @"", @"none", @"xt6502", @"xt6502", @"6502", @"", @"", @"xt6502", NO, @"", @"", @"", @"xex", @"", @"", @"", @"", @"macos-arm64", @"so dylib", @"",
                @"6502 xt6502 xt"),
        ];
    });
    return t;
    }

+ (nullable XTTarget*)rowForToken:(NSString*)token
    {
    for (XTTarget* r in [self rows])
        if ([r.name isEqualToString:token] || [r.aliases containsObject:token])
            return r;
    return nil;
    }

- (NSArray<NSString*>*)macros
    {
    NSMutableArray<NSString*>* m = [NSMutableArray array];
    [m addObject:[@"ARCH_" stringByAppendingString:self.cpu]];
    [m addObject:[@"OS_" stringByAppendingString:self.os]];
    if ([self.os isEqualToString:@"macos"] || [self.os isEqualToString:@"ios"])
        [m addObject:@"OS_darwin"];
    if ([@[ @"macos", @"ios", @"linux", @"android" ] containsObject:self.os])
        [m addObject:@"OS_unix"];
    if (![self.libc isEqualToString:@"none"])
        [m addObject:[@"LIBC_" stringByAppendingString:self.libc]];
    if (self.env)
        [m addObject:[@"ENV_" stringByAppendingString:self.env]];
    return m;
    }

- (NSString*)describe
    {
    NSMutableString* s = [NSMutableString string];
    [s appendFormat:@"target %@\n", self.name];
    [s appendFormat:@"cpu %@\n", self.cpu];
    if (self.cpuVariant)
        [s appendFormat:@"cpu-variant %ld\n", (long)self.cpuVariant];
    [s appendFormat:@"os %@\n", self.os];
    if (self.env)
        [s appendFormat:@"env %@\n", self.env];
    [s appendFormat:@"libc %@\n", self.libc];
    [s appendFormat:@"legacy %@\n", self.legacy];
    [s appendFormat:@"backend %@\n", self.backend];
    [s appendFormat:@"codegen %@\n", self.codegen];
    if (self.platformLayer)
        [s appendFormat:@"platform-layer %@\n", self.platformLayer];
    [s appendFormat:@"abi %@\n", self.abi];
    if (self.lseAtomics)
        [s appendString:@"lse-atomics\n"];
    if (self.appleSdk)
        [s appendFormat:@"apple-sdk %@\n", self.appleSdk];
    if (self.matmul)
        [s appendFormat:@"matmul %@\n", self.matmul];
    [s appendFormat:@"format %@\n", self.exeFormat];
    if (self.crt)
        [s appendFormat:@"runtime %@ %@\n", self.crt, self.runtime];
    if (self.interp)
        [s appendFormat:@"interp %@\n", self.interp];
    if (self.needed.count)
        {
        [s appendString:@"needed"];
        for (NSString* w in self.needed)
            [s appendFormat:@" %@", w];
        [s appendString:@"\n"];
        }
    [s appendFormat:@"bundle-platform %@\n", self.bundlePlatform];
    [s appendFormat:@"lib-exts %@\n", [self.libExts componentsJoinedByString:@" "]];
    [s appendFormat:@"checked-runtime %@\n", self.checkedRuntime.length ? self.checkedRuntime : @"-"];
    [s appendString:@"par-kernels"];
    for (NSString* w in self.parKernels)
        [s appendFormat:@" %@", w];
    [s appendString:@"\n"];
    [s appendString:@"support"];
    for (NSString* c in self.supportChain)
        [s appendFormat:@" %@", c];
    [s appendString:@"\n"];
    [s appendString:@"macros"];
    for (NSString* m in self.macros)
        [s appendFormat:@" %@", m];
    [s appendString:@"\n"];
    [s appendString:@"aliases"];
    for (NSString* a in self.aliases)
        [s appendFormat:@" %@", a];
    [s appendString:@"\n"];
    return s;
    }

@end
