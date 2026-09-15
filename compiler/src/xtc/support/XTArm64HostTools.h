/****************************************************************************\
|* XTArm64HostTools.h — how THIS host builds and runs arm64 binaries.
|*
|* Two harnesses need it: the arm64 codegen tests and the corpus sweep. Both
|* assemble a fixture's arm64 asm against a C stub and then execute the result,
|* and both were written on a Mac, where that is `clang -arch arm64` and a
|* direct exec.
|*
|* On Linux neither half works as written: `-arch` is a Darwin driver flag, the
|* host clang targets x86-64 and rejects the asm outright ("invalid instruction
|* mnemonic 'uxtb'"), and nothing there executes arm64 to begin with.
|*
|* But arm64 is NOT Mac-bound — that is the point of this file. The NDK's cross
|* clang emits aarch64 ELF against bionic and qemu-aarch64 runs it, exercising
|* the SAME backend output. What genuinely needs Apple hardware is the macOS
|* PLATFORM surface — Mach-O, dyld, dSYM — not instruction selection.
|*
|* Caller's responsibility on a non-Apple host: run the backend's asm through
|* XTMachOToElfArm64() first. It is Mach-O flavoured (`_sa`, @PAGE/@PAGEOFF),
|* and an ELF linker looks for `sa` while the asm says `_sa`.
|*
|* Overridable, so no toolchain path is baked into a harness:
|*   XC_ARM64_CC        compiler to assemble/link with
|*   XC_ARM64_RUN       launcher for the result ("" = exec directly)
|*   XC_ANDROID_SYSROOT bionic for qemu -L
|*
|* Header-only static inline, like XTRegexCompat.h: the harnesses that need it
|* are separate binaries with separate object lists.
\****************************************************************************/

#ifndef XTARM64HOSTTOOLS_H
#define XTARM64HOSTTOOLS_H

#import <Foundation/Foundation.h>

/// Split a space-separated env command ("clang -arch arm64", "qemu-aarch64 -L /p").
static inline NSArray<NSString*>* XTArm64SplitCmd(const char* s)
    {
    NSMutableArray<NSString*>* out = [NSMutableArray array];
    for (NSString* p in [@(s) componentsSeparatedByString:@" "])
        if (p.length)
            [out addObject:p];
    return out.count ? out : nil;
    }

/// The NDK's per-API cross clang, if reachable. API 24 matches what the android
/// target itself uses (androidNdkClangEx in main.m).
static inline NSString* XTArm64NdkClang(void)
    {
    NSFileManager* fm = [NSFileManager defaultManager];
    const char* nh = getenv("ANDROID_NDK_HOME");
    if (!nh || !*nh)
        return nil;
    NSString* tc = [@(nh) stringByAppendingPathComponent:@"toolchains/llvm/prebuilt"];
    for (NSString* host in [fm contentsOfDirectoryAtPath:tc error:NULL])
        {
        NSString* cc = [tc stringByAppendingPathComponent:
                               [host stringByAppendingPathComponent:@"bin/aarch64-linux-android24-clang"]];
        if ([fm isExecutableFileAtPath:cc])
            return cc;
        }
    return nil;
    }

/// Base argv for compiling/linking arm64 — append your own sources and `-o`.
/// Suitable for `/usr/bin/env`. Nil when this host cannot build arm64 at all.
static inline NSArray<NSString*>* XTArm64ClangArgv(void)
    {
    const char* env = getenv("XC_ARM64_CC");
    if (env && *env)
        return XTArm64SplitCmd(env);
#if defined(__APPLE__)
    return @[ @"clang", @"-arch", @"arm64" ]; // the host IS arm64
#else
    NSString* cc = XTArm64NdkClang();
    return cc ? @[ cc ] : nil;
#endif
    }

/// Launcher argv to prefix the built binary with, or nil to exec it directly.
static inline NSArray<NSString*>* XTArm64RunPrefix(void)
    {
    const char* env = getenv("XC_ARM64_RUN");
    // set-but-empty = exec directly
    if (env)
        {
        if (!*env)
            return nil;
        return XTArm64SplitCmd(env);
        }
#if defined(__APPLE__)
    return nil; // native arm64
#else
    const char* sr = getenv("XC_ANDROID_SYSROOT");
    return @[ @"qemu-aarch64", @"-L",
              sr && *sr ? @(sr) : @"/opt/xc-pools/android-sysroot" ];
#endif
    }

/// YES when the built fixture will run against BIONIC rather than Darwin, and
/// the backend therefore has to be told so. Two codegen decisions ride on it,
/// and both are silent failures rather than build errors:
///
///   setAapcs64Abi:YES   Android is plain AAPCS64; Darwin passes the C-variadic
///                       tail differently and packs overflow args to natural
///                       size. Get it wrong and printf prints garbage —
///                       cvariadic_call and exit_flush are the guard fixtures,
///                       and they were exactly what failed on the box.
///   setLseAtomics:NO    Apple Silicon is ARMv8.5 and always has LSE; Android's
///                       floor is plain armv8-a and the NDK assembler REFUSES
///                       ldaddlh outright ("instruction requires: lse"), which
///                       is what took out every threads_* fixture.
///
/// The driver forwards both to xcc-cg-arm64
/// for the same reason, and a harness that links with the NDK needs them too.
static inline BOOL XTArm64UsesBionicAbi(void)
    {
#if defined(__APPLE__)
    return NO;
#else
    return YES;
#endif
    }

/// YES when the backend's Mach-O-flavoured asm must be rewritten to ELF first.
static inline BOOL XTArm64NeedsElfDialect(void)
    {
#if defined(__APPLE__)
    return NO;
#else
    return YES;
#endif
    }

#endif /* XTARM64HOSTTOOLS_H */
