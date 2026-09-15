#import "XA6502.h"

// Opcode table entry: { mnemonic, addressing mode, opcode byte }
typedef struct
    {
    const char* mnemonic;
    XAAddressingMode mode;
    uint8_t opcode;
    } XAOpcodeEntry;

// Complete 6502 official opcode table (151 entries)
static const XAOpcodeEntry sOpcodeTable[] = {
    // ADC
    {"ADC", XAModeImmediate, 0x69},
    {"ADC", XAModeZeroPage, 0x65},
    {"ADC", XAModeZeroPageX, 0x75},
    {"ADC", XAModeAbsolute, 0x6D},
    {"ADC", XAModeAbsoluteX, 0x7D},
    {"ADC", XAModeAbsoluteY, 0x79},
    {"ADC", XAModeIndexedIndirectX, 0x61},
    {"ADC", XAModeIndirectIndexedY, 0x71},
    // AND
    {"AND", XAModeImmediate, 0x29},
    {"AND", XAModeZeroPage, 0x25},
    {"AND", XAModeZeroPageX, 0x35},
    {"AND", XAModeAbsolute, 0x2D},
    {"AND", XAModeAbsoluteX, 0x3D},
    {"AND", XAModeAbsoluteY, 0x39},
    {"AND", XAModeIndexedIndirectX, 0x21},
    {"AND", XAModeIndirectIndexedY, 0x31},
    // ASL
    {"ASL", XAModeAccumulator, 0x0A},
    {"ASL", XAModeZeroPage, 0x06},
    {"ASL", XAModeZeroPageX, 0x16},
    {"ASL", XAModeAbsolute, 0x0E},
    {"ASL", XAModeAbsoluteX, 0x1E},
    // BCC, BCS, BEQ, BMI, BNE, BPL, BVC, BVS
    {"BCC", XAModeRelative, 0x90},
    {"BCS", XAModeRelative, 0xB0},
    {"BEQ", XAModeRelative, 0xF0},
    {"BMI", XAModeRelative, 0x30},
    {"BNE", XAModeRelative, 0xD0},
    {"BPL", XAModeRelative, 0x10},
    {"BVC", XAModeRelative, 0x50},
    {"BVS", XAModeRelative, 0x70},
    // BIT
    {"BIT", XAModeZeroPage, 0x24},
    {"BIT", XAModeAbsolute, 0x2C},
    // BRK
    {"BRK", XAModeImplied, 0x00},
    // CLC, CLD, CLI, CLV
    {"CLC", XAModeImplied, 0x18},
    {"CLD", XAModeImplied, 0xD8},
    {"CLI", XAModeImplied, 0x58},
    {"CLV", XAModeImplied, 0xB8},
    // CMP
    {"CMP", XAModeImmediate, 0xC9},
    {"CMP", XAModeZeroPage, 0xC5},
    {"CMP", XAModeZeroPageX, 0xD5},
    {"CMP", XAModeAbsolute, 0xCD},
    {"CMP", XAModeAbsoluteX, 0xDD},
    {"CMP", XAModeAbsoluteY, 0xD9},
    {"CMP", XAModeIndexedIndirectX, 0xC1},
    {"CMP", XAModeIndirectIndexedY, 0xD1},
    // CPX
    {"CPX", XAModeImmediate, 0xE0},
    {"CPX", XAModeZeroPage, 0xE4},
    {"CPX", XAModeAbsolute, 0xEC},
    // CPY
    {"CPY", XAModeImmediate, 0xC0},
    {"CPY", XAModeZeroPage, 0xC4},
    {"CPY", XAModeAbsolute, 0xCC},
    // DEC
    {"DEC", XAModeZeroPage, 0xC6},
    {"DEC", XAModeZeroPageX, 0xD6},
    {"DEC", XAModeAbsolute, 0xCE},
    {"DEC", XAModeAbsoluteX, 0xDE},
    // DEX, DEY
    {"DEX", XAModeImplied, 0xCA},
    {"DEY", XAModeImplied, 0x88},
    // EOR
    {"EOR", XAModeImmediate, 0x49},
    {"EOR", XAModeZeroPage, 0x45},
    {"EOR", XAModeZeroPageX, 0x55},
    {"EOR", XAModeAbsolute, 0x4D},
    {"EOR", XAModeAbsoluteX, 0x5D},
    {"EOR", XAModeAbsoluteY, 0x59},
    {"EOR", XAModeIndexedIndirectX, 0x41},
    {"EOR", XAModeIndirectIndexedY, 0x51},
    // INC
    {"INC", XAModeZeroPage, 0xE6},
    {"INC", XAModeZeroPageX, 0xF6},
    {"INC", XAModeAbsolute, 0xEE},
    {"INC", XAModeAbsoluteX, 0xFE},
    // INX, INY
    {"INX", XAModeImplied, 0xE8},
    {"INY", XAModeImplied, 0xC8},
    // JMP
    {"JMP", XAModeAbsolute, 0x4C},
    {"JMP", XAModeIndirect, 0x6C},
    // JSR
    {"JSR", XAModeAbsolute, 0x20},
    // LDA
    {"LDA", XAModeImmediate, 0xA9},
    {"LDA", XAModeZeroPage, 0xA5},
    {"LDA", XAModeZeroPageX, 0xB5},
    {"LDA", XAModeAbsolute, 0xAD},
    {"LDA", XAModeAbsoluteX, 0xBD},
    {"LDA", XAModeAbsoluteY, 0xB9},
    {"LDA", XAModeIndexedIndirectX, 0xA1},
    {"LDA", XAModeIndirectIndexedY, 0xB1},
    // LDX
    {"LDX", XAModeImmediate, 0xA2},
    {"LDX", XAModeZeroPage, 0xA6},
    {"LDX", XAModeZeroPageY, 0xB6},
    {"LDX", XAModeAbsolute, 0xAE},
    {"LDX", XAModeAbsoluteY, 0xBE},
    // LDY
    {"LDY", XAModeImmediate, 0xA0},
    {"LDY", XAModeZeroPage, 0xA4},
    {"LDY", XAModeZeroPageX, 0xB4},
    {"LDY", XAModeAbsolute, 0xAC},
    {"LDY", XAModeAbsoluteX, 0xBC},
    // LSR
    {"LSR", XAModeAccumulator, 0x4A},
    {"LSR", XAModeZeroPage, 0x46},
    {"LSR", XAModeZeroPageX, 0x56},
    {"LSR", XAModeAbsolute, 0x4E},
    {"LSR", XAModeAbsoluteX, 0x5E},
    // NOP
    {"NOP", XAModeImplied, 0xEA},
    // ORA
    {"ORA", XAModeImmediate, 0x09},
    {"ORA", XAModeZeroPage, 0x05},
    {"ORA", XAModeZeroPageX, 0x15},
    {"ORA", XAModeAbsolute, 0x0D},
    {"ORA", XAModeAbsoluteX, 0x1D},
    {"ORA", XAModeAbsoluteY, 0x19},
    {"ORA", XAModeIndexedIndirectX, 0x01},
    {"ORA", XAModeIndirectIndexedY, 0x11},
    // PHA, PHP, PLA, PLP
    {"PHA", XAModeImplied, 0x48},
    {"PHP", XAModeImplied, 0x08},
    {"PLA", XAModeImplied, 0x68},
    {"PLP", XAModeImplied, 0x28},
    // ROL
    {"ROL", XAModeAccumulator, 0x2A},
    {"ROL", XAModeZeroPage, 0x26},
    {"ROL", XAModeZeroPageX, 0x36},
    {"ROL", XAModeAbsolute, 0x2E},
    {"ROL", XAModeAbsoluteX, 0x3E},
    // ROR
    {"ROR", XAModeAccumulator, 0x6A},
    {"ROR", XAModeZeroPage, 0x66},
    {"ROR", XAModeZeroPageX, 0x76},
    {"ROR", XAModeAbsolute, 0x6E},
    {"ROR", XAModeAbsoluteX, 0x7E},
    // RTI, RTS
    {"RTI", XAModeImplied, 0x40},
    {"RTS", XAModeImplied, 0x60},
    // SBC
    {"SBC", XAModeImmediate, 0xE9},
    {"SBC", XAModeZeroPage, 0xE5},
    {"SBC", XAModeZeroPageX, 0xF5},
    {"SBC", XAModeAbsolute, 0xED},
    {"SBC", XAModeAbsoluteX, 0xFD},
    {"SBC", XAModeAbsoluteY, 0xF9},
    {"SBC", XAModeIndexedIndirectX, 0xE1},
    {"SBC", XAModeIndirectIndexedY, 0xF1},
    // SEC, SED, SEI
    {"SEC", XAModeImplied, 0x38},
    {"SED", XAModeImplied, 0xF8},
    {"SEI", XAModeImplied, 0x78},
    // STA
    {"STA", XAModeZeroPage, 0x85},
    {"STA", XAModeZeroPageX, 0x95},
    {"STA", XAModeAbsolute, 0x8D},
    {"STA", XAModeAbsoluteX, 0x9D},
    {"STA", XAModeAbsoluteY, 0x99},
    {"STA", XAModeIndexedIndirectX, 0x81},
    {"STA", XAModeIndirectIndexedY, 0x91},
    // STX
    {"STX", XAModeZeroPage, 0x86},
    {"STX", XAModeZeroPageY, 0x96},
    {"STX", XAModeAbsolute, 0x8E},
    // STY
    {"STY", XAModeZeroPage, 0x84},
    {"STY", XAModeZeroPageX, 0x94},
    {"STY", XAModeAbsolute, 0x8C},
    // TAX, TAY, TSX, TXA, TXS, TYA
    {"TAX", XAModeImplied, 0xAA},
    {"TAY", XAModeImplied, 0xA8},
    {"TSX", XAModeImplied, 0xBA},
    {"TXA", XAModeImplied, 0x8A},
    {"TXS", XAModeImplied, 0x9A},
    {"TYA", XAModeImplied, 0x98},

    // ── xt CPU additions ─────────────────────────────────────────
    // SP-relative loads/stores/arith (docs/6502/6502-embellishments.md §2).
    {"LDA", XAModeSPRelative, 0xB2},
    {"STA", XAModeSPRelative, 0x92},
    {"LDX", XAModeSPRelative, 0x42},
    {"STX", XAModeSPRelative, 0x02},
    {"LDY", XAModeSPRelative, 0x52},
    {"STY", XAModeSPRelative, 0x12},
    {"ADC", XAModeSPRelative, 0x72},
    {"SBC", XAModeSPRelative, 0xF2},
    {"CMP", XAModeSPRelative, 0xD2},

    // Stack-pointer indirect / indexed (§2b). $x3 column, anchored at the
    // bottom: IR[5]=mode (0=(),Y, 1=,X), IR[4]=load/store.
    {"LDA", XAModeSPIndirectIndexedY, 0x03},
    {"STA", XAModeSPIndirectIndexedY, 0x13},
    {"LDA", XAModeSPIndexedX, 0x23},
    {"STA", XAModeSPIndexedX, 0x33},

    // Stack adjustment: ADD SP, #signed8 (§2 "Stack adjustment").
    {"ADD", XAModeStackAdjust, 0x22},

    // Prologue / epilogue helpers (§3).
    {"PSH", XAModeImmediate, 0x32},
    {"PLL", XAModeImmediate, 0x62},

    // Direct push/pop of X and Y (§2 "Push and pop X and Y directly").
    // Doc has $64 listed for both POP X and POP Y; resolved here by
    // assigning POP Y to $74 (the otherwise-NOP slot).
    {"PHX", XAModeImplied, 0x44},
    {"PHY", XAModeImplied, 0x54},
    {"PLX", XAModeImplied, 0x64},
    {"PLY", XAModeImplied, 0x74},

    // BRA — 65C02-style unconditional relative branch (§2).
    {"BRA", XAModeRelative, 0x80},
};

static const NSUInteger sOpcodeTableCount = sizeof(sOpcodeTable) / sizeof(sOpcodeTable[0]);

@interface XA6502 ()
@property(nonatomic) NSMutableDictionary<NSString*, NSMutableDictionary<NSNumber*, NSNumber*>*>* table;
@property(nonatomic) NSSet<NSString*>* branchMnemonics;
@end

@implementation XA6502

/****************************************************************************\
|* Return the singleton 6502 opcode table instance, creating it on first use.
|* @return  The shared XA6502 instance.
\****************************************************************************/
+ (instancetype)sharedInstance
    {
    static XA6502* inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      inst = [[XA6502 alloc] init];
    });
    return inst;
    }

/****************************************************************************\
|* Initialise the opcode table from the static 6502 instruction set data.
|* @return  A fully populated opcode lookup table.
\****************************************************************************/
- (instancetype)init
    {
    self = [super init];
    if (self)
        {
        _table = [NSMutableDictionary dictionary];
        for (NSUInteger i = 0; i < sOpcodeTableCount; i++)
            {
            NSString* mn = [[NSString stringWithUTF8String:sOpcodeTable[i].mnemonic] uppercaseString];
            NSMutableDictionary* modes = _table[mn];
            if (!modes)
                {
                modes = [NSMutableDictionary dictionary];
                _table[mn] = modes;
                }
            modes[@(sOpcodeTable[i].mode)] = @(sOpcodeTable[i].opcode);
            }
        _branchMnemonics = [NSSet setWithArray:@[ @"BCC", @"BCS", @"BEQ", @"BMI", @"BNE", @"BPL", @"BVC", @"BVS", @"BRA" ]];
        }
    return self;
    }

/****************************************************************************\
|* Returns the opcode byte for a mnemonic + addressing mode, or -1 if invalid.
|* @param mnemonic  The 3-letter instruction mnemonic (case-insensitive).
|* @param mode      The addressing mode to look up.
|* @return  The opcode byte (0x00-0xFF), or -1 if the combination is invalid.
\****************************************************************************/
- (NSInteger)opcodeForMnemonic:(NSString*)mnemonic mode:(XAAddressingMode)mode
    {
    NSDictionary* modes = _table[mnemonic.uppercaseString];
    NSNumber* op = modes[@(mode)];
    return op ? op.integerValue : -1;
    }

/****************************************************************************\
|* Returns YES if the mnemonic is a valid 6502 instruction.
|* @param mnemonic  The mnemonic string to check (case-insensitive).
|* @return  YES if the mnemonic exists in the opcode table.
\****************************************************************************/
- (BOOL)isValidMnemonic:(NSString*)mnemonic
    {
    return _table[mnemonic.uppercaseString] != nil;
    }

/****************************************************************************\
|* Returns YES if the mnemonic is a branch instruction (BCC, BCS, BEQ, etc.).
|* @param mnemonic  The mnemonic string to check (case-insensitive).
|* @return  YES if the mnemonic is a conditional branch.
\****************************************************************************/
- (BOOL)isBranchMnemonic:(NSString*)mnemonic
    {
    return [_branchMnemonics containsObject:mnemonic.uppercaseString];
    }

@end
