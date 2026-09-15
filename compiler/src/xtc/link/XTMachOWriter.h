// XTMachOWriter — serialises a laid-out arm64 image to a Mach-O MH_EXECUTE.
// Phase 2 of the self-hosted native toolchain (private:docs/Design/native-toolchain.md).
// Now handles libSystem imports: a `bl _extern` whose target is not a local
// symbol becomes a __stubs entry that jumps through a __got slot, bound at load
// via LC_DYLD_INFO_ONLY bind opcodes. Unsigned (Phase 3 adds the signature).
#import <Foundation/Foundation.h>
#import "XAArm64Assembler.h"

NS_ASSUME_NONNULL_BEGIN

@interface XTMachOWriter : NSObject

/****************************************************************************\
|* Which Apple platform every image this process writes is stamped for
|* (LC_BUILD_VERSION): @"macos" (the default — platform 1, minos 11.0),
|* @"ios" (platform 2, minos 15.0) or @"ios-sim" (platform 7, minos 15.0).
|* Process-wide because one xcc-ln-arm64 invocation builds exactly one
|* image; the flag comes in on its command line. iOS.md Stage 0.
\****************************************************************************/
+ (void)setApplePlatform:(nullable NSString*)platform;

// The `.tbd` target triples the current platform's exports are listed under.
// Exposed so a test can pin the mapping — reading the wrong triples yields an
// EMPTY export set, which is silent until dyld refuses at launch (bugs/028).
+ (NSArray<NSString*>*)tbdTargets;
// Build an executable from assembled __text bytes. `symbols` maps
// name -> offset-in-text (defined labels). `fixups` are the assembler's
// unresolved references; Branch26 fixups to names not in `symbols` become
// libSystem imports (stub + GOT + bind). Returns the complete Mach-O bytes.
+ (NSData*)executableFromText:(NSData*)text
                  entryOffset:(uint64_t)entryOffset
                      symbols:(NSDictionary<NSString*, NSNumber*>*)symbols
                         data:(nullable NSData*)data
                  dataSymbols:(nullable NSSet<NSString*>*)dataSymbols
                       fixups:(NSArray<XAArm64Fixup*>*)fixups;

// As above, but link against shared libraries: each entry of `dylibs` is
// @{@"install": <install-name NSString>, @"symbols": <NSSet of exported symbol
// names>}; an unresolved Branch26 whose target one of them exports binds to that
// dylib (ordinal 2..), everything else to libSystem (ordinal 1). `rpaths` are
// LC_RPATH search paths (e.g. @loader_path and the dylib's directory). Use
// +inspectDylib: to build the dylib entries from a .dylib on disk.
+ (NSData*)executableFromText:(NSData*)text
                  entryOffset:(uint64_t)entryOffset
                      symbols:(NSDictionary<NSString*, NSNumber*>*)symbols
                         data:(nullable NSData*)data
                  dataSymbols:(nullable NSSet<NSString*>*)dataSymbols
                       fixups:(NSArray<XAArm64Fixup*>*)fixups
                       dylibs:(NSArray<NSDictionary*>*)dylibs
                       rpaths:(NSArray<NSString*>*)rpaths
                // Bug 066: how many bytes at the END of `data` are the __mod_init_func pointer
                // array (XAArm64Assembler.modInitLength). They get their own
                // S_MOD_INIT_FUNC_POINTERS section — the bytes and addresses are unchanged, but
                // without the section type dyld treats them as inert data and no load-time
                // constructor ever runs. 0 when the image has none.
                modInitLength:(NSUInteger)modInitLength
                 // Bug 069: ObjC metadata sections carved out of `data`, each
                 // @{name, seg, flags, off, size} in blob coordinates. The runtime finds its
                 // metadata BY SECTION, so a selref delivered as anonymous __data is never
                 // uniqued and every message send misses. Empty for a link with no ObjC.
                 objcSections:(NSArray<NSDictionary*>*)objcSections;

// Read a Mach-O dylib's install name (LC_ID_DYLIB) and its exported symbols
// (the external-defined range of LC_SYMTAB). Returns @{@"install":..,
// @"symbols":NSSet} or nil if the file can't be parsed.
+ (nullable NSDictionary*)inspectDylib:(NSString*)path;

// Read a `.tbd` text stub (TBD v4, the SDK's stand-in for a shared-cache dylib):
// its `install-name` and the exported `symbols` whose `targets` include
// arm64-macos. Returns the same @{@"install":.., @"symbols":NSSet} shape as
// +inspectDylib: (so the binder treats an SDK stub exactly like an on-disk
// dylib), or nil if the file isn't a parseable tbd.
+ (nullable NSDictionary*)inspectTbd:(NSString*)path;

// Build a RELOCATABLE OBJECT (MH_OBJECT) from the same pieces the executable
// path takes: assembled __text, optional __data, the defined symbols
// (name -> offset in whichever section owns it, per `dataSymbols`), and the
// assembler's unresolved `fixups`. Every fixup target that is not a defined
// symbol becomes an undefined entry, and every fixup becomes a relocation —
// which is the whole difference between an object and an executable: nothing is
// bound, the linker binds it later. See private:docs/Design/separate-compilation.md.
+ (NSData*)objectFromText:(NSData*)text
                  symbols:(NSDictionary<NSString*, NSNumber*>*)symbols
                     data:(nullable NSData*)data
              dataSymbols:(nullable NSSet<NSString*>*)dataSymbols
                   fixups:(NSArray<XAArm64Fixup*>*)fixups
                  exports:(nullable NSSet<NSString*>*)exports
                  commons:(nullable NSDictionary<NSString*, NSArray<NSNumber*>*>*)commons;

// Read a BARE MH_OBJECT file, in the same shape objectsInArchive: returns per
// member — so an explicitly-listed .o and an archive member merge identically.
+ (nullable NSDictionary*)objectAtPath:(NSString*)path;

// Parse a static `ar` archive of arm64 MH_OBJECT members. Returns one dict per
// object: @{@"text":NSData, @"symbols":@{name→offset}, @"relocs":@[…]} — the
// pieces to pull in and relocate when a `-l<static>` provides a referenced symbol.
// nil if not a parseable archive.
+ (nullable NSArray<NSDictionary*>*)objectsInArchive:(NSString*)path;

// Build an MH_DYLIB (shared library) from assembled __text/__data. Same layout
// machinery as the executable minus __PAGEZERO/LC_MAIN, plus: LC_ID_DYLIB
// (`installName`, e.g. @rpath/libFoo.dylib); an export trie + external symtab
// range for every name in `exports` (the library's public functions, so a
// client's `#import <Foo>` binds against them); and, when `iface` is non-nil, a
// custom `__XTC,__iface` section carrying the module-interface JSON that the
// importer reads back. Ad-hoc signed like the executable. Loads at base 0.
+ (NSData*)dylibFromText:(NSData*)text
             installName:(NSString*)installName
                 exports:(NSSet<NSString*>*)exports
                   iface:(nullable NSData*)iface
                 symbols:(NSDictionary<NSString*, NSNumber*>*)symbols
                    data:(nullable NSData*)data
             dataSymbols:(nullable NSSet<NSString*>*)dataSymbols
                  fixups:(NSArray<XAArm64Fixup*>*)fixups
           // As above: the trailing __mod_init_func byte count. A library's constructors
           // are dyld's job — nothing outside it can call them — so for a dylib this is
           // the ONLY thing that makes them run.
           modInitLength:(NSUInteger)modInitLength
            objcSections:(NSArray<NSDictionary*>*)objcSections;
@end

NS_ASSUME_NONNULL_END
