/****************************************************************************\
|* XTMachOToElfArm64.h
|*
|* The arm64 backend emits MACH-O flavoured assembly — leading-underscore
|* symbols, @PAGE/@PAGEOFF addressing, __mod_init_func. Anything that wants to
|* feed that to an ELF toolchain has to rewrite it first.
|*
|* This was a pair of static functions inside main.m, serving `-A android`
|* alone. It moved out here when the arm64 CODEGEN TESTS needed it too: on a
|* Linux CI box those fixtures are assembled by a cross clang and run under
|* qemu-aarch64, and without the rewrite every one of them fails to link with
|* `undefined symbol: sa` — the ELF linker looking for `sa` while the asm says
|* `_sa`.
|*
|* One implementation, two consumers, so the two cannot drift — the same reason
|* android-glue.c has a single checked-in assembly translation rather than an
|* inline copy.
\****************************************************************************/

#import <Foundation/Foundation.h>

/// Rewrite Mach-O flavoured arm64 assembly into the ELF dialect.
///
/// `shared` selects the extra treatment a .so needs: in shared output a global
/// symbol is preemptible, so lld refuses the backend's `adrp`+`add :lo12:` pair
/// and its `.quad <method>` vtables ("recompile with -fPIC"). Marking every
/// `.globl` `.hidden` and giving every `.comm` a concrete `.bss` definition
/// makes them non-preemptible and lld then keeps the pc-relative form.
NSString* XTMachOToElfArm64Ex(NSString* asm_, BOOL shared);

/// The executable case — `XTMachOToElfArm64Ex(asm_, NO)`.
NSString* XTMachOToElfArm64(NSString* asm_);
