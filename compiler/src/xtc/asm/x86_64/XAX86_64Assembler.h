// XAX86_64Assembler — an in-house x86-64 assembler for the self-hosted Linux
// last stage (private:docs/Design/native-toolchain.md). Consumes the Intel-syntax text
// the x86_64 backend emits (`.intel_syntax noprefix`) and produces machine code
// plus a symbol table and relocation fixups, so a Mac can build a Linux ELF with
// no Linux tooling at all.
//
// Unlike AArch64 (fixed 32-bit), x86-64 is variable length: an instruction is
// [legacy prefixes][REX][opcode][ModRM][SIB][disp][imm]. Encoding is therefore
// table-plus-form driven rather than one bitfield per mnemonic. Every form is
// byte-verified against clang by tests/asm-x86_64/oracle-diff.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(int, XAX86FixupKind) {
    XAX86FixupRel32, // call/jmp/jcc rel32 -> R_X86_64_PLT32/PC32
    XAX86FixupPC32,  // RIP-relative operand displacement
    XAX86FixupAbs64, // .quad <symbol>
    // A PC-relative slot in DATA, not text. Our assembler never emits one — the
    // back end has no position-independent jump tables — but musl's vfprintf
    // does, so an archive member can carry it. The kind is what tells the writer
    // WHICH section a fixup patches, so this cannot just reuse PC32.
    XAX86FixupPC32Data,
    // R_X86_64_[REX_]GOTPCRELX (41/42, finding #17) — a RELAXABLE load from a
    // GOT slot (`mov reg, [rip + sym@GOTPCREL]`), which musl members carry
    // (getenv.lo reads &__environ this way). A static link defines everything,
    // so there is no GOT: the writer RELAXES it per the psABI — the mov opcode
    // (0x8b, two bytes before the displacement) becomes lea (0x8d) and the
    // displacement resolves S + A - P exactly as PC32 does. Any other opcode
    // under this reloc takes a real GOT slot (GotRef below) instead.
    XAX86FixupGotLoad,
    // R_X86_64_GOTPCREL (9) — a NON-relaxable reference to a GOT slot. The
    // instruction reads the slot's 8 bytes as data (libpq carries a `cmpq`
    // weak-symbol null check and two SSE loads of slot contents), so mov→lea
    // relaxation cannot apply: the writer allocates a link-time GOT — one
    // 8-byte slot per symbol, holding its absolute address — and resolves the
    // displacement slot-relative (G + A - P). A GotLoad whose opcode is not a
    // relaxable mov is downgraded to this too, rather than refused.
    XAX86FixupGotRef,
    // R_X86_64_TPOFF32 (23) — a LOCAL-EXEC thread-local offset (%fs-relative,
    // negative). The linker main resolves it to a constant before the writer
    // runs: `addend` arrives holding the final tpoff and the writer just
    // stores it — no symbol lookup, no section base. mimalloc's per-thread
    // heap pointer is what first needed it.
    XAX86FixupTpoff32,
};

@interface XAX86_64Fixup : NSObject
@property(nonatomic) uint64_t offset; // byte offset in the section
@property(nonatomic) XAX86FixupKind kind;
@property(nonatomic, copy) NSString* symbol;
@property(nonatomic) int64_t addend;
@end

@interface XAX86_64Assembler : NSObject
// Encode ONE instruction line (no labels/directives). Used by the oracle-diff
// harness to byte-compare against clang. Returns nil + error if unencodable.
- (nullable NSData*)encodeOne:(NSString*)line error:(NSError**)error;

// Assemble a full `.s` (labels, directives, instructions) into __text bytes.
- (nullable NSData*)assemble:(NSString*)source error:(NSError**)error;

@property(nonatomic, readonly) NSArray<XAX86_64Fixup*>* fixups;
@property(nonatomic, readonly) NSDictionary<NSString*, NSNumber*>* symbols;
@property(nonatomic, readonly) NSData* data; // .data bytes
@property(nonatomic, readonly) NSSet<NSString*>* dataSymbols;
// Names carried by a `.globl` directive — what a shared object exports. Local
// labels (block labels, string literals) are defined but never global.
@property(nonatomic, readonly) NSSet<NSString*>* globalSymbols;
// `.comm` COMMON (tentative-definition) symbols: name -> @[size, byteAlign].
// A single-unit image materialises them with -demoteCommonsToLocalData; a `-c`
// object hands them to the ELF writer as SHN_COMMON so they merge across units.
@property(nonatomic, readonly) NSDictionary<NSString*, NSArray<NSNumber*>*>* commonSymbols;
- (void)demoteCommonsToLocalData;
@end

NS_ASSUME_NONNULL_END
