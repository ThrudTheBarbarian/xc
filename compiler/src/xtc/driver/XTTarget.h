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

// Every row, in the order both compilers list them.
+ (NSArray<XTTarget*>*)rows;
// The row a -A token names (its canonical name or an alias), or nil.
+ (nullable XTTarget*)rowForToken:(NSString*)token;
// --print-target: the row, one field per line, as the port prints it.
- (NSString*)describe;
@end

NS_ASSUME_NONNULL_END
