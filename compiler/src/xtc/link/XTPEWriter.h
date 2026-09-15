// XTPEWriter — in-house PE/COFF writer, the Windows leg of the self-hosted
// toolchain (private:docs/Design/native-toolchain.md §13). Lets any host produce a
// Windows x86-64 binary with no mingw, no lld-link, no Windows SDK.
//
// The instruction encoder is shared with the Linux target: `xtc -A win64` uses
// the same XTX86_64Backend and emits the same Intel-syntax directive set, so
// XAX86_64Assembler needs no changes at all. What is new is the container.
//
// How PE differs from ELF, in the ways that matter here:
//
//   * Everything is expressed as an RVA — an offset from ImageBase — and file
//     offsets are a SEPARATE alignment (FileAlignment 512 vs SectionAlignment
//     4096). ELF lets p_offset and p_vaddr be congruent and largely interchange;
//     PE does not, so each section carries both independently.
//   * There is no DT_NEEDED/GOT. Imports go through an Import Directory Table
//     naming each DLL, with a parallel ILT/IAT pair of thunks; the loader
//     overwrites the IAT with resolved addresses. A `call foo` therefore has to
//     become `call <stub>` where the stub is `jmp qword ptr [rip + IAT slot]` —
//     the same shape as the thunks the ELF writer synthesizes for GLOB_DAT.
//   * Windows has no stable syscall ABI, so unlike Linux a freestanding binary
//     CANNOT avoid imports: kernel32.dll is the floor.
#import <Foundation/Foundation.h>
#import "XAX86_64Assembler.h"

NS_ASSUME_NONNULL_BEGIN

@interface XTPEWriter : NSObject

// Write a bare COFF relocatable object: text and data verbatim, every remaining
// fixup recorded as a relocation, and a symbol table saying what this unit
// defines and what it still needs. `globalSymbols` (the `.globl` names) decides
// EXTERNAL vs STATIC storage class — a defined name that was never `.globl`
// must stay static, or two objects with a same-named helper collide at link.
//
// COFF has no explicit addend field: the addend is written INLINE into the
// patched bytes, which is why this returns a copy of the sections rather than
// leaving the caller's alone.
+ (nullable NSData*)objectFromText:(NSData*)text
                              data:(NSData*)data
                           symbols:(NSDictionary<NSString*, NSNumber*>*)symbols
                       dataSymbols:(NSSet<NSString*>*)dataSymbols
                     globalSymbols:(NSSet<NSString*>*)globalSymbols
                            fixups:(NSArray<XAX86_64Fixup*>*)fixups
                             error:(NSError**)error;

// Read one back, in the same dictionary shape the Mach-O and ELF readers
// return. Addends are normalised to the assembler's convention (`S + addend -
// P`), so a caller never has to know REL32 implies a +4.
+ (nullable NSDictionary*)objectAtPath:(NSString*)path;
+ (nullable NSDictionary*)objectFromData:(NSData*)d;
// Every COFF object in a `!<arch>` static library, each dict as objectAtPath:
// returns plus a `member` name. nil if the file is not an archive at all.
+ (nullable NSArray<NSDictionary*>*)objectsInArchive:(NSString*)path;

// Link an assembled translation unit into a console-subsystem .exe.
//
// `symbols` maps every defined name to its section-relative offset; a name in
// `dataSymbols` is an offset into `data`, everything else into `text`. Fixup
// offsets are likewise section-relative, disambiguated by kind: Rel32/PC32 sit
// in text, Abs64 in data.
//
// Undefined symbols are resolved as DLL imports via `imports`, which maps a DLL
// name to the symbols taken from it (e.g. @{@"kernel32.dll": @[@"ExitProcess"]}).
// A symbol that is neither defined nor listed there is an error rather than a
// zero-filled call.
+ (nullable NSData*)executableFromText:(NSData*)text
                                  data:(NSData*)data
                               symbols:(NSDictionary<NSString*, NSNumber*>*)symbols
                           dataSymbols:(NSSet<NSString*>*)dataSymbols
                                fixups:(NSArray<XAX86_64Fixup*>*)fixups
                           entrySymbol:(NSString*)entrySymbol
                               imports:(NSDictionary<NSString*, NSArray<NSString*>*>*)imports
                                 error:(NSError**)error;

@end

NS_ASSUME_NONNULL_END
