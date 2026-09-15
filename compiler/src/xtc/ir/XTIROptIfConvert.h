// XTIROptIfConvert.h — branchless if-conversion of predicate diamonds.
//
// A short-circuit `&&`/`||` and a value-producing `if (cond) x = v;` both lower
// to the same CFG diamond:
//
//     H:  …; CondBranch cond, T, J      (or  cond, J, T)
//     T:  …pure value computation…; Branch J
//     J:  r = Phi [(H, vH), (T, vT)]; …
//
// When the middle arm T is provably side-effect-free (only Const / arithmetic /
// compares / casts / address math — no load, store, call, div or other trap),
// the diamond is branchless-equivalent: each join phi becomes
// `Select(cond, vT, vH)` (orientation depending on which arm is the taken one).
// The pass moves T's pure instructions into H, replaces every join phi with a
// Select, and makes H fall straight through to J.
//
// This removes both the branches AND the boolean temporaries that crossed the
// block boundaries (and so spilled/reloaded each loop iteration) — the dominant
// cost on scalar byte-classification / parsing / comparator code. Chained
// diamonds (the `c >= LO && c <= HI` → `if` pattern) collapse one at a time as
// the pass re-recognises from the live CFG.
//
// Profile-gated (arm64 on: it has `csel` and a flat register file; the 6502
// keeps the branches), -O2+.
#import <Foundation/Foundation.h>
#import "XTIROptPass.h"

@class XTIROptTargetProfile;

NS_ASSUME_NONNULL_BEGIN

@interface XTIROptIfConvert : NSObject <XTIROptPass>
@property(nonatomic, strong, nullable) XTIROptTargetProfile* profile;
@end

NS_ASSUME_NONNULL_END
