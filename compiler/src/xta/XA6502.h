#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, XAAddressingMode) {
    XAModeImplied,          // e.g. NOP, RTS
    XAModeAccumulator,      // e.g. ASL A
    XAModeImmediate,        // e.g. LDA #$nn
    XAModeZeroPage,         // e.g. LDA $nn
    XAModeZeroPageX,        // e.g. LDA $nn,X
    XAModeZeroPageY,        // e.g. LDX $nn,Y
    XAModeAbsolute,         // e.g. LDA $nnnn
    XAModeAbsoluteX,        // e.g. LDA $nnnn,X
    XAModeAbsoluteY,        // e.g. LDA $nnnn,Y
    XAModeIndirect,         // e.g. JMP ($nnnn)
    XAModeIndexedIndirectX, // e.g. LDA ($nn,X)
    XAModeIndirectIndexedY, // e.g. LDA ($nn),Y
    XAModeRelative,         // e.g. BEQ label

    // xt CPU additions (docs/6502/6502-embellishments.md §§2-3).
    XAModeSPRelative,  // e.g. LDA +5,SP  — signed-8-bit offset
    XAModeStackAdjust, // e.g. ADD SP,#imm — signed-8-bit immediate

    // xt stack-indirect / indexed (docs/6502/6502-embellishments.md §2b).
    XAModeSPIndirectIndexedY, // e.g. LDA (+5,SP),Y — deref a stacked pointer
    XAModeSPIndexedX,         // e.g. LDA +5,SP,X — indexed in-frame access
};

/****************************************************************************\
|* Returns the instruction byte size for a given addressing mode (1, 2, or 3).
\****************************************************************************/
static inline NSUInteger XAByteSizeForMode(XAAddressingMode mode)
    {
    switch (mode)
        {
    case XAModeImplied:
    case XAModeAccumulator:
        return 1;
    case XAModeImmediate:
    case XAModeZeroPage:
    case XAModeZeroPageX:
    case XAModeZeroPageY:
    case XAModeIndexedIndirectX:
    case XAModeIndirectIndexedY:
    case XAModeRelative:
    case XAModeSPRelative:
    case XAModeStackAdjust:
    case XAModeSPIndirectIndexedY:
    case XAModeSPIndexedX:
        return 2;
    case XAModeAbsolute:
    case XAModeAbsoluteX:
    case XAModeAbsoluteY:
    case XAModeIndirect:
        return 3;
        }
    return 1;
    }

/****************************************************************************\
|* The 6502 opcode lookup table.
|* Provides opcodeForMnemonic:mode: and lists valid modes for each mnemonic.
\****************************************************************************/
@interface XA6502 : NSObject

+ (instancetype)sharedInstance;

/****************************************************************************\
|* Returns the opcode byte for a mnemonic + addressing mode, or -1 if invalid.
\****************************************************************************/
- (NSInteger)opcodeForMnemonic:(NSString*)mnemonic mode:(XAAddressingMode)mode;

/****************************************************************************\
|* Returns YES if the mnemonic is a valid 6502 instruction.
\****************************************************************************/
- (BOOL)isValidMnemonic:(NSString*)mnemonic;

/****************************************************************************\
|* Returns YES if the mnemonic is a branch instruction (BCC, BCS, BEQ, etc.).
\****************************************************************************/
- (BOOL)isBranchMnemonic:(NSString*)mnemonic;

@end

NS_ASSUME_NONNULL_END
