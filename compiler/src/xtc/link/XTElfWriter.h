// XTElfWriter — in-house ELF64 writer for the self-hosted Linux last stage
// (private:docs/Design/native-toolchain.md §12). Lets a Mac produce a runnable Linux
// binary with no Linux tooling: no /opt/clang/linux, no ld.lld, no musl.
//
// Two shapes, in increasing order of machinery:
//   * static ET_EXEC — ELF header + PT_LOAD(s) + code. No dynamic linker, no
//     relocations at load, no PLT/GOT, no code signing (unlike Mach-O). This is
//     the simplest thing that can run, and it is a strict subset of the next.
//   * ET_DYN (.so)  — adds .dynsym/.dynstr + a hash table, .rela.dyn/.rela.plt,
//     .got/.plt and PT_DYNAMIC. Measured against a real xtc-built .so, only three
//     relocation types actually occur: R_X86_64_RELATIVE / GLOB_DAT / JUMP_SLOT.
//     Because we are the whole-program linker, internal references are resolved
//     at link time and never become dynamic relocations.
#import <Foundation/Foundation.h>
#import "XAX86_64Assembler.h"

NS_ASSUME_NONNULL_BEGIN

@interface XTElfWriter : NSObject

// Link an assembled translation unit into a static ET_EXEC. `symbols` maps every
// defined name to its section-relative offset; a name in `dataSymbols` is an
// offset into `data`, everything else into `text`. Fixup offsets are likewise
// section-relative, disambiguated by kind: Rel32/PC32 sit in text, Abs64 in data.
//
// Static means static: every referenced symbol must be defined here, so an
// unresolved fixup is an error rather than something deferred to a loader.
// `absSymbols` names entries in `symbols` whose value is an ABSOLUTE address
// rather than a section offset — the home of the weak-undefined-resolves-to-0
// rule (_DYNAMIC in a static musl link) and nothing else so far.
+ (nullable NSData*)staticExecutableFromText:(NSData*)text
                                        data:(NSData*)data
                                     symbols:(NSDictionary<NSString*, NSNumber*>*)symbols
                                 dataSymbols:(NSSet<NSString*>*)dataSymbols
                                  absSymbols:(nullable NSSet<NSString*>*)absSymbols
                                      fixups:(NSArray<XAX86_64Fixup*>*)fixups
                                 entrySymbol:(NSString*)entrySymbol
                                         bss:(nullable NSData*)bss
                                  bssSymbols:(nullable NSArray<NSString*>*)bssSymbols
                                    bssAlign:(uint64_t)bssAlign
                                       error:(NSError**)error;

// A statically-linked ET_EXEC for x86-64 Linux. `text` is the assembled code,
// `entryOffset` the entry point's offset within it, `data` the initialised data
// (mapped read-write after the code). Returns the complete file bytes.
+ (NSData*)staticExecutableFromText:(NSData*)text
                        entryOffset:(uint64_t)entryOffset
                               data:(nullable NSData*)data;

// Link an assembled translation unit into an ET_DYN shared object. Same inputs
// as the static case plus `globalSymbols` (what to export — the `.globl` names)
// and the two pieces of dynamic-linking metadata: the SONAME this library is
// known by, and the DT_NEEDED list of libraries it depends on.
//
// Undefined symbols are legal here, unlike the static case: each one becomes a
// GOT slot with a GLOB_DAT relocation, reached through a synthesized `jmp [rip+
// got]` thunk so the backend's direct `call` still works. Only FUNCTION imports
// can be handled that way — an undefined DATA symbol would need the referencing
// instruction rewritten to an indirection, so it is reported rather than
// silently mislinked.
// Same machinery, one flag apart: a dynamically-linked executable is an ET_DYN
// with an entry point and a PT_INTERP naming the loader. Pass `entrySymbol` to
// get one (a PIE), or nil for a plain library. This is how a self-hosted program
// links against a self-hosted .so — DT_NEEDED plus the same GOT thunks.
+ (nullable NSData*)sharedObjectFromText:(NSData*)text
                                    data:(NSData*)data
                                 symbols:(NSDictionary<NSString*, NSNumber*>*)symbols
                             dataSymbols:(NSSet<NSString*>*)dataSymbols
                           globalSymbols:(NSSet<NSString*>*)globalSymbols
                                  fixups:(NSArray<XAX86_64Fixup*>*)fixups
                                  soname:(NSString*)soname
                                  needed:(nullable NSArray<NSString*>*)needed
                             entrySymbol:(nullable NSString*)entrySymbol
                                 runpath:(nullable NSString*)runpath
                                   iface:(nullable NSData*)iface
                                     bss:(nullable NSData*)bss
                              bssSymbols:(nullable NSArray<NSString*>*)bssSymbols
                                bssAlign:(uint64_t)bssAlign
                                   error:(NSError**)error;

// Write an ET_REL relocatable object: the text and data verbatim, every
// remaining fixup recorded as a relocation, and a symbol table that says what
// this unit defines and what it still needs. `globalSymbols` (the `.globl`
// names) decides STB_GLOBAL vs STB_LOCAL — a defined name that was never
// `.globl` must stay local, or two objects with a same-named static helper
// collide at link. Undefined symbols are the point here, not an error.
+ (nullable NSData*)objectFromText:(NSData*)text
                              data:(NSData*)data
                           symbols:(NSDictionary<NSString*, NSNumber*>*)symbols
                       dataSymbols:(NSSet<NSString*>*)dataSymbols
                     globalSymbols:(NSSet<NSString*>*)globalSymbols
                           commons:(nullable NSDictionary<NSString*, NSArray<NSNumber*>*>*)commons
                            fixups:(NSArray<XAX86_64Fixup*>*)fixups
                             error:(NSError**)error;

// Read an ET_REL back. Returns the same dictionary shape XTMachOWriter's
// +objectAtPath: does — text/data blobs, symnames + parallel symdefs, the
// external defs, and the relocations against each blob — so the two linkers'
// merge loops stay recognisably the same code. nil if the file is not an
// ELF64 little-endian ET_REL with a symbol table.
+ (nullable NSDictionary*)objectAtPath:(NSString*)path;

// The same, from bytes already in hand — an archive member, which is an ET_REL
// embedded in a `.a` rather than a file of its own.
+ (nullable NSDictionary*)objectFromData:(NSData*)d;

// Every ET_REL member of a `!<arch>` static library, in archive order, each as
// the dictionary above plus `@"member"` naming it. nil if the file is not an
// archive. Members that are not ELF objects (the symbol index, the long-name
// table) are skipped rather than reported: they are not objects and their
// absence from the result is the answer, not an error.
+ (nullable NSArray<NSDictionary*>*)objectsInArchive:(NSString*)path;

// The virtual address the text will land at, so a caller can resolve absolute
// references into it before handing the bytes over. It depends on the program
// header count, hence on whether there is a data segment — ask, don't mirror the
// arithmetic (a caller that guessed wrong pointed a string at header padding).
+ (uint64_t)textAddressWithDataSegment:(BOOL)hasData;

// Read an ET_DYN shared object's public contract, for a link that CONSUMES it:
//   @"soname"    NSString  — DT_SONAME (or the file's basename if absent)
//   @"undefined" NSArray<NSString*> — its UND global/weak dynsyms, i.e. the
//                symbols the .so imports and expects the loading scope to supply.
// A main executable that links this .so must define AND export those, so the
// loader resolves the .so's imports against the one initialised libc in the exe
// (musl is a static libc — there is no libc.so to fall back on). nil if the file
// is not a readable ELF64 shared object.
+ (nullable NSDictionary*)sharedInfoAtPath:(NSString*)path;

@end

NS_ASSUME_NONNULL_END
