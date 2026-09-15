// XAArm32Assembler — an in-house ARM (A32) assembler, so `-c` for arm9 needs no
// external toolchain. The sibling of XAArm64Assembler and XAX86_64Assembler,
// and the last one the tree was missing: until now the arm9 path shelled out to
// `arm-none-eabi-gcc`, which is fine on a development host, impossible on the
// device (a Cortex-A9 has no gcc), and wrong on a Windows host that has no
// cross-toolchain either.
//
// It assembles the SUBSET the arm9 back end emits, not ARM in general — about
// forty mnemonics, one addressing-mode family, the VFP forms, and a literal
// pool. That is what makes it tractable. Anything outside the subset is
// reported BY NAME rather than skipped: an assembler that quietly drops an
// instruction produces an object that links and crashes.
//
// This is a port of `selfhost/asm/Arm32.xc`, which is differentially tested
// against `arm-none-eabi-as` (selfhost/tools/as9-diff.sh). The two must agree
// byte for byte; `tests/asm-arm32` is the shared corpus.
//
// A32 encoding, for the forms used here (bits 31-28 = condition, 0b1110 = al):
//
//   data processing   cond 00 I opcode S Rn Rd operand2
//   movw/movt         cond 0011 0x00 imm4 Rd imm12
//   load/store        cond 01 I P U B W L Rn Rd offset12
//   branch            cond 101 L imm24 (signed, words, PC-relative +8)
//   push/pop          cond 100 P U S W L Rn register_list
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// ELF32 ARM relocation types — the two this subset produces.
typedef NS_ENUM(uint32_t, XAArm32RelocKind) {
    XAArm32RelocAbs32 = 0x02, // R_ARM_ABS32: a `.word sym` or a pool entry
    XAArm32RelocCall = 0x1C,  // R_ARM_CALL:  a `bl`/`b` to an unresolved name
};

// One entry in the object's symbol table.
@interface XAArm32Symbol : NSObject
@property(nonatomic, copy) NSString* name;
@property(nonatomic) uint32_t section; // 0 undefined, 1 .text, 2 .data, 3 COMMON
@property(nonatomic) uint32_t value;   // offset in the section (alignment, for COMMON)
@property(nonatomic) uint32_t size;
@property(nonatomic) BOOL isGlobal;
@property(nonatomic) BOOL isFunction;
@property(nonatomic) BOOL hidden;
@end

// One relocation: patch `offset` in `section` against `symbol`.
@interface XAArm32Reloc : NSObject
@property(nonatomic) uint32_t section; // 1 .text, 2 .data
@property(nonatomic) uint32_t offset;
@property(nonatomic, copy) NSString* symbol;
@property(nonatomic) XAArm32RelocKind kind;
@end

@interface XAArm32Assembler : NSObject

// Assemble a full `.s` into the `.text` bytes. Returns nil and sets `error`
// when the source uses something outside the subset — never a partial result,
// because a missing instruction is not a diagnosable failure downstream.
- (nullable NSData*)assemble:(NSString*)source error:(NSError**)error;

@property(nonatomic, readonly) NSData* text;
@property(nonatomic, readonly) NSData* data;
@property(nonatomic, readonly) NSArray<XAArm32Symbol*>* symbols;
@property(nonatomic, readonly) NSArray<XAArm32Reloc*>* relocations;
// Mnemonics the subset does not cover, in first-seen order. Named rather than
// counted, so a gap can be closed rather than merely noticed.
@property(nonatomic, readonly) NSArray<NSString*>* missing;

@end

NS_ASSUME_NONNULL_END
