// XTElf32Writer — an ELF32 ARM relocatable object, written by hand.
//
// XAArm32Assembler turns the arm9 back end's `.s` into bytes; this puts those
// bytes in the container a linker will take. Together they replace the
// `arm-none-eabi-gcc` call the arm9 `-c` path used to make — which is the whole
// point, because the device has no gcc and neither does a Windows host.
//
// It writes what an assembler writes and no more: `.text`, `.data`, `.bss` (as
// COMMON symbols), a symbol table, and one relocation section per relocated
// section. Not a linker — no dynamic sections, no PLT, no GOT.
//
// A port of `selfhost/asm/Elf32.xc`. The oracle is the toolchain itself: hand
// the object to `arm-none-eabi-gcc` in place of the `.s` it would have
// assembled, and the program that comes out has to run and print the same
// thing. An object that is subtly wrong does not link, or links and crashes —
// either way it is not silent.
#import <Foundation/Foundation.h>
#import "XAArm32Assembler.h"

NS_ASSUME_NONNULL_BEGIN

@interface XTElf32Writer : NSObject

// Build the object file bytes from what the assembler recorded.
+ (NSData*)objectFromText:(NSData*)text
                     data:(NSData*)data
                  symbols:(NSArray<XAArm32Symbol*>*)symbols
              relocations:(NSArray<XAArm32Reloc*>*)relocations;

// Link into the loader-hosted ET_DYN image the XTOS loader takes — the other
// half of the arm9 toolchain, and the last piece that belonged to GNU.
//
// What the loader reads (its `xtld.c`), and therefore what has to be right:
// PT_LOAD segments and a PT_DYNAMIC; DT_HASH, because the loader takes the
// symbol COUNT from its `nchain` and nothing else tells it; DT_SYMTAB /
// DT_STRTAB / DT_SYMENT so it can find `main` by name; and DT_REL with an
// R_ARM_RELATIVE for every absolute address, because the image is loaded at a
// bias nobody knows until it is loaded.
//
// A reference to a symbol this image does not define is an IMPORT: it goes into
// .dynsym as undefined and the loader resolves it. A CALL to one goes through a
// two-word veneer (`ldr pc, [pc, #-4]` and the word the loader fills in),
// because a `bl` displacement cannot reach an address nobody knows yet — which
// is all a PLT entry is when nothing is lazy.
//
// `needed` names the DT_NEEDED libraries; `soname` is recorded when non-nil.
// Returns nil and sets `error` on an undefined symbol that is not an import.
+ (nullable NSData*)sharedObjectFromText:(NSData*)text
                                    data:(NSData*)data
                                 symbols:(NSArray<XAArm32Symbol*>*)symbols
                             relocations:(NSArray<XAArm32Reloc*>*)relocations
                                  needed:(NSArray<NSString*>*)needed
                                  soname:(nullable NSString*)soname
                                   iface:(nullable NSData*)iface
                                   error:(NSError**)error;

@end

// Read back an ET_REL this writer produced: @{text, data, symbols, relocs},
// where symbols/relocs are the assembler's own XAArm32Symbol / XAArm32Reloc so a
// caller can merge an object into an assembled unit and hand the whole thing to
// sharedObjectFromText:. nil if it is not an ELF32 ARM relocatable, or carries a
// relocation type this compiler does not emit.
@interface XTElf32Writer (Read)
+ (nullable NSDictionary*)objectFromData:(NSData*)d;
@end

NS_ASSUME_NONNULL_END
