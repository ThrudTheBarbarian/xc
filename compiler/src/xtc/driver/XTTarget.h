// XTTarget.h — the target table: one row per target, found by its -A token.
//
// private:docs/Design/targets.md. A target is named by one token, canonical
// cpu-os[-env|-libc] (arm64-macos, x86_64-linux, arm64-android, ...), with
// today's short names and the gcc/clang triples as aliases of the same row.
// The port's Target.xc holds the same rows, field for field, in the same order.
//
// Step 1: the rows name the target and carry `legacy`, the -A spelling the
// option parser still decides by; the decisions move onto row fields one group
// at a time after this.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface XTTarget : NSObject
@property(nonatomic, readonly, copy) NSString* name;      // canonical token
@property(nonatomic, readonly, copy) NSArray<NSString*>* aliases;
@property(nonatomic, readonly, copy) NSString* cpu;       // arm64, x86_64, armv7, wasm32, m68k, 6502
@property(nonatomic, readonly) NSInteger cpuVariant;      // 68000 / 68030 on m68k; 0 elsewhere
@property(nonatomic, readonly, copy) NSString* os;        // macos, ios, android, linux, windows, xtos, web, tos, xt
@property(nonatomic, readonly, copy, nullable) NSString* env;  // simulator, or nil
@property(nonatomic, readonly, copy) NSString* libc;      // darwin, bionic, glibc, musl, msvcrt, xtos, none
@property(nonatomic, readonly, copy) NSString* legacy;    // the -A spelling the parser decides by today
@property(nonatomic, readonly, copy) NSString* backend;   // platform key: front end target, opt profile (arm64, x86_64, win64, arm9, atarist, wasm32, xt6502)
@property(nonatomic, readonly, copy) NSString* codegen;   // the code generator, xcc-cg-<codegen>
// support/<dir>/lib searched before support/generic/lib, in order; empty for
// 6502, whose layout names its platform.
@property(nonatomic, readonly, copy) NSArray<NSString*>* supportChain;
// The third-party tree's platform layer, searched before the arch's directory
// (ios, ios-sim, android), or nil.
@property(nonatomic, readonly, copy, nullable) NSString* platformLayer;
// The calling convention: darwin64, aapcs64, sysv, win64, aapcs-vfp, wasm, m68k, xt6502.
@property(nonatomic, readonly, copy) NSString* abi;
// arm64: the baseline has the LSE atomics (Apple Silicon); NO for plain armv8-a
// (Android's floor, a Pi 4's A72). NO elsewhere, where it means nothing.
@property(nonatomic, readonly) BOOL lseAtomics;
// The Apple SDK whose frameworks `#import <F>` may name (macosx, iphoneos,
// iphonesimulator), or nil: frameworks are on exactly when it is set.
@property(nonatomic, readonly, copy, nullable) NSString* appleSdk;
// The par kernel forms the target's runtime can run: metal, ptx, spirv, wgsl.
@property(nonatomic, readonly, copy) NSArray<NSString*>* parKernels;
// The matrix-multiply kernels idiom-matmul calls at -O2+: sme (arm64 macOS,
// checked for at run time), x86 (one per vector tier), or nil.
@property(nonatomic, readonly, copy, nullable) NSString* matmul;
// The executable format: macho, elf-pie, elf-dyn, elf-static, elf32-dyn, pe,
// wasm, prg, xex.
@property(nonatomic, readonly, copy) NSString* exeFormat;
// arm64 so far: the runtime files from support/arm64/runtime (crt, runtime),
// an ELF executable's PT_INTERP, and its DT_NEEDED before the program's own.
@property(nonatomic, readonly, copy, nullable) NSString* crt;
@property(nonatomic, readonly, copy, nullable) NSString* runtime;
@property(nonatomic, readonly, copy, nullable) NSString* interp;
@property(nonatomic, readonly, copy) NSArray<NSString*>* needed;
// A bundle's platform directory, <os>-<cpu> (the port's --bundle writes it).
@property(nonatomic, readonly, copy) NSString* bundlePlatform;
// A library's file extensions, in the order `#import <X>` tries lib<X>.<ext>.
@property(nonatomic, readonly, copy) NSArray<NSString*>* libExts;
// -fbounds-check's reporter, linked from support/<cpu>/runtime (macOS and iOS:
// a backtrace with arguments), or "" where Checked.xc reports instead.
@property(nonatomic, readonly, copy) NSString* checkedRuntime;

// Every row, in the order both compilers list them.
+ (NSArray<XTTarget*>*)rows;
// The row a -A token names (its canonical name or an alias), or nil.
+ (nullable XTTarget*)rowForToken:(NSString*)token;
// The library defines the row generates (target-table step 3): ARCH_<cpu>,
// OS_<os>, OS_darwin (macos, ios), OS_unix (macos, ios, linux, android),
// LIBC_<libc> (not for none), ENV_<env>; each defined as 1, in this order.
- (NSArray<NSString*>*)macros;
// --print-target: the row, one field per line, as the port prints it.
- (NSString*)describe;
@end

NS_ASSUME_NONNULL_END
