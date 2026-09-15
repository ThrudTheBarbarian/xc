// XTElfArm64Writer — in-house ELF64/AArch64 writer, the Android counterpart of
// XTElfWriter (x86-64). Same job, same shape, different machine: it turns one
// assembled translation unit — XAArm64Assembler's text/data/symbols/fixups —
// into a file bionic's loader can map, with no NDK clang and no ld.lld.
//
// Only ET_DYN is emitted, because that is all Android runs: an app is a PIE
// (entry point + PT_INTERP /system/bin/linker64) and a NativeActivity payload
// is a `.so` (SONAME, no entry). They differ by two program headers and a
// couple of dynamic tags, so one method covers both — pass `entrySymbol` for
// the executable, nil for the library.
//
// We are the whole-program linker, so an intra-image reference is resolved here
// and never becomes a dynamic relocation. Exactly two kinds survive to load
// time: R_AARCH64_RELATIVE for each `.quad <symbol>` (a vtable word — an
// absolute address the loader must bias) and R_AARCH64_GLOB_DAT for each symbol
// we import from bionic. A `bl` to an import goes through a 16-byte thunk that
// loads the import's GOT slot and branches, so the backend's direct call needs
// no rewriting.
#import <Foundation/Foundation.h>
#import "XAArm64Assembler.h"

NS_ASSUME_NONNULL_BEGIN

@interface XTElfArm64Writer : NSObject

// `symbols` maps every defined name to its offset within its own section; a name
// in `dataSymbols` is an offset into `data`, everything else into `text`.
// `globalSymbols` (the `.globl` names) decides what is exported. Any symbol a
// fixup names but nothing defines is an import: it gets a GOT slot, a GLOB_DAT,
// and — if reached by `bl` — a thunk.
//
// `entrySymbol` non-nil makes a PIE (adds PT_PHDR + PT_INTERP and e_entry);
// nil makes a shared object named by `soname`. `needed` is the DT_NEEDED list.
//
// `modInitLength` is the size of the load-time constructor pointer array, which
// the caller has appended to the TAIL of `data` (8-aligned) with its fixups
// shifted to match — the same convention XTMachOWriter takes. It becomes
// DT_INIT_ARRAY / DT_INIT_ARRAYSZ. Zero means the program has no constructors.
// Without those two tags the pointers are inert words the loader never walks,
// which is bug 124 (and bug 066 before it, on Mach-O).
+ (nullable NSData*)sharedObjectFromText:(NSData*)text
                                    data:(NSData*)data
                                 symbols:(NSDictionary<NSString*, NSNumber*>*)symbols
                             dataSymbols:(NSSet<NSString*>*)dataSymbols
                           globalSymbols:(NSSet<NSString*>*)globalSymbols
                                  fixups:(NSArray<XAArm64Fixup*>*)fixups
                                  soname:(nullable NSString*)soname
                                  needed:(nullable NSArray<NSString*>*)needed
                             entrySymbol:(nullable NSString*)entrySymbol
                           modInitLength:(NSUInteger)modInitLength
                                   error:(NSError**)error;

@end

NS_ASSUME_NONNULL_END
