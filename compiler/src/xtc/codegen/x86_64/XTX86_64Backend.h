#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class XTIRModule;

// x86-64 (System V AMD64) backend — emits Linux/musl x86-64 assembly (Intel
// syntax) from the shared IR. Sibling of XTArm64Backend / XTArm9Backend /
// XT6502Backend / XTM68kBackend. Driven by xtcg-x86_64; the driver assembles +
// links the .s with the musl cross-clang + ld.lld into a static ELF.
@interface XTX86_64Backend : NSObject

// IR module → x86-64 assembly text.
+ (NSString*)assemblyFromModule:(XTIRModule*)mod;

// Select the Win64 ABI (rcx/rdx/r8/r9 + 32-byte shadow space, PE/COFF) instead
// of the default System V AMD64. Set once by xtcg-win64 before codegen.
+ (void)setWin64ABI:(BOOL)win64;

// Thread-safe ARC — the refcount update as a LOCK-prefixed read-modify-write
// (private:docs/Design/threading.md §4.1). Resolved per module inside
// assemblyFromModule: (atomic exactly when the module spawns a thread); this
// override forces it: 1 = always, 0 = never, -1 (default) = decide.
+ (void)setThreadSafeARCOverride:(NSInteger)mode;
+ (BOOL)threadSafeARC;

@end

NS_ASSUME_NONNULL_END
