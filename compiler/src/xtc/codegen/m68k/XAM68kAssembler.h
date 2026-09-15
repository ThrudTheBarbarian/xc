/****************************************************************************\
|* XAM68kAssembler.h — minimal Motorola 68000/68030 assembler producing a
|* GEMDOS $601A executable (the Atari ST .PRG/.TOS/.TTP/.ACC format).
|*
|* The 68k counterpart to xta/XAAssembler. Two passes: pass 1 assigns
|* label addresses by sizing each instruction; pass 2 encodes bytes and
|* records relocations for absolute-long symbol references. Output is a
|* separate .text/.data/.bss segments (bss is size-only) linked at 0,
|* wrapped in the $601A header + DRI relocation stream. The encoder grows lazily,
|* covering exactly the instructions XTM68kBackend + the crt0 emit; it is
|* cross-validated by running the result in sim68k (xst).
\****************************************************************************/
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface XAM68kAssembler : NSObject

/// Target CPU (68000 default, 68030). On 68020+ the PIC PC-relative call /
/// jump references use 32-bit displacements (bsr.l/bra.l), lifting the
/// ±32KB limit of the 68000 16-bit form.
@property(nonatomic) NSInteger cpu;

/// GOT/a5 position-independent model (base-68000 only). When YES and cpu is
/// pre-68020, symbolic jsr/jmp/lea/pea references are routed through a Global
/// Offset Table addressed by a5 (emitted as `_GOT` at the end of the image),
/// lifting the ±32KB PC-relative limit. The backend's _start sets a5.
@property(nonatomic) BOOL pic;

/// Assemble Motorola-syntax 68k asm text into a GEMDOS $601A image.
/// Returns nil and sets *error on failure.
- (nullable NSData*)assemble:(NSString*)source error:(NSString* _Nullable* _Nullable)error;

@end

NS_ASSUME_NONNULL_END
