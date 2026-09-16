#import "XAArm32Assembler.h"

@implementation XAArm32Symbol
@end

@implementation XAArm32Reloc
@end

@implementation XAArm32Assembler
    {
    NSMutableData* _text;
    NSMutableData* _data;
    NSMutableArray<XAArm32Symbol*>* _syms;
    NSMutableArray<XAArm32Reloc*>* _relocs;
    NSMutableArray<NSString*>* _missing;

    NSMutableDictionary<NSString*, NSNumber*>* _labels;
    // A NUMERIC label (`1:`) may be defined many times; `1f` is the next one
    // forward and `1b` the last one back, so they are a list of positions
    // rather than a binding.
    NSMutableDictionary<NSString*, NSMutableArray<NSNumber*>*>* _numeric;
    NSMutableArray<NSString*>* _pool;      // symbols pending a literal-pool word
    NSMutableArray<NSNumber*>* _poolSites; // …and the ldr each was loaded by

    NSArray<NSString*>* _lines;
    uint32_t _pass;
    uint32_t _section; // 1 .text, 2 .data
    uint32_t _pc, _dataPc;
    NSString* _failWhy;

    // Set by splitMnemonic for the instruction being encoded.
    NSString* _base;
    int _cond;
    BOOL _setFlags;
    }

- (NSData*)text
    {
    return _text ?: [NSData data];
    }
- (NSData*)data
    {
    return _data ?: [NSData data];
    }
- (NSArray<XAArm32Symbol*>*)symbols
    {
    return _syms ?: @[];
    }
- (NSArray<XAArm32Reloc*>*)relocations
    {
    return _relocs ?: @[];
    }
- (NSArray<NSString*>*)missing
    {
    return _missing ?: @[];
    }

// A mnemonic outside the subset. Recorded by name and only once, and the FIRST
// one becomes the error — a file that uses three unknown forms should report
// the one to implement, not a count.
- (void)giveUp:(NSString*)what
    {
    if (!_missing)
        _missing = [NSMutableArray array];
    if ([_missing containsObject:what])
        return;
    [_missing addObject:what];
    if (!_failWhy)
        _failWhy = what;
    }

// ── Registers and conditions ──────────────────────────────────────────────
// r0-r15, plus the three names that are register numbers by another spelling:
// sp is r13, lr r14, pc r15 (and ip r12).
static int regNumber(NSString* t)
    {
    if (!t.length)
        return -1;
    if ([t isEqualToString:@"sp"])
        return 13;
    if ([t isEqualToString:@"lr"])
        return 14;
    if ([t isEqualToString:@"pc"])
        return 15;
    if ([t isEqualToString:@"ip"])
        return 12;
    if ([t characterAtIndex:0] != 'r')
        return -1;
    uint32_t v = 0;
    for (NSUInteger i = 1; i < t.length; i++)
        {
        unichar c = [t characterAtIndex:i];
        if (c < '0' || c > '9')
            return -1;
        v = v * 10 + (uint32_t)(c - '0');
        }
    return v <= 15 ? (int)v : -1;
    }

// The four-bit condition field. `al` (always) is the absence of a suffix.
static int condCode(NSString* c)
    {
    if (!c.length)
        return 14;
    static NSDictionary<NSString*, NSNumber*>* m;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      m = @{@"eq" : @0,
            @"ne" : @1,
            @"hs" : @2,
            @"cs" : @2,
            @"lo" : @3,
            @"cc" : @3,
            @"mi" : @4,
            @"pl" : @5,
            @"vs" : @6,
            @"vc" : @7,
            @"hi" : @8,
            @"ls" : @9,
            @"ge" : @10,
            @"lt" : @11,
            @"gt" : @12,
            @"le" : @13,
            @"al" : @14};
    });
    NSNumber* n = m[c];
    return n ? n.intValue : -1;
    }

// The data-processing opcode field, or -1 for a mnemonic that is not one.
static int dpOpcode(NSString* m)
    {
    static NSDictionary<NSString*, NSNumber*>* t;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      t = @{@"and" : @0,
            @"eor" : @1,
            @"sub" : @2,
            @"rsb" : @3,
            @"add" : @4,
            @"adc" : @5,
            @"sbc" : @6,
            @"rsc" : @7,
            @"tst" : @8,
            @"teq" : @9,
            @"cmp" : @10,
            @"cmn" : @11,
            @"orr" : @12,
            @"mov" : @13,
            @"bic" : @14,
            @"mvn" : @15};
    });
    NSNumber* n = t[m];
    return n ? n.intValue : -1;
    }

static BOOL isKnownBase(NSString* m)
    {
    static NSSet<NSString*>* s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      s = [NSSet setWithArray:@[ @"b", @"bl", @"bx", @"blx", @"ldr", @"str",
                                 @"ldrb", @"strb", @"ldrh", @"strh", @"ldrsb", @"ldrsh",
                                 @"push", @"pop", @"movw", @"movt", @"uxtb", @"uxth", @"sxtb",
                                 @"sxth", @"mul", @"mla", @"umull", @"smull",
                                 @"lsl", @"lsr", @"asr", @"ror",
                                 @"svc", @"swi", @"udf",
                                 // Barriers and the exclusive pair — what atomic ARC and the
                                 // thread primitives compile to on this target.
                                 @"dmb", @"dsb", @"isb",
                                 @"ldrex", @"ldrexb", @"ldrexh", @"strex", @"strexb", @"strexh",
                                 // Count-leading-zeros, the exclusive-monitor clear, the
                                 // double-word pair and the coprocessor move — what a compiled
                                 // runtime uses and a hand-written one wants.
                                 @"clz", @"clrex", @"ldrd", @"strd", @"mrc", @"mcr" ]];
    });
    return [s containsObject:m];
    }

static BOOL isExtendOp(NSString* b)
    {
    return [b isEqualToString:@"uxtb"] || [b isEqualToString:@"uxth"] || [b isEqualToString:@"sxtb"] || [b isEqualToString:@"sxth"];
    }
static BOOL isMemOp(NSString* b)
    {
    return [b isEqualToString:@"ldr"] || [b isEqualToString:@"str"] || [b isEqualToString:@"ldrb"] || [b isEqualToString:@"strb"] || [b isEqualToString:@"ldrh"] || [b isEqualToString:@"strh"] || [b isEqualToString:@"ldrsb"] || [b isEqualToString:@"ldrsh"];
    }
static BOOL isShiftOp(NSString* b)
    {
    return [b isEqualToString:@"lsl"] || [b isEqualToString:@"lsr"] || [b isEqualToString:@"asr"] || [b isEqualToString:@"ror"];
    }
// The barrier domain, by name. 0xFFFFFFFF for one this does not know, so an
// unrecognised option is reported rather than silently assembled as `sy`.
static uint32_t barrierOption(NSString* o)
    {
    if ([o isEqualToString:@"sy"])
        return 15;
    if ([o isEqualToString:@"st"])
        return 14;
    if ([o isEqualToString:@"ish"])
        return 11;
    if ([o isEqualToString:@"ishst"])
        return 10;
    if ([o isEqualToString:@"nsh"])
        return 7;
    if ([o isEqualToString:@"nshst"])
        return 6;
    if ([o isEqualToString:@"osh"])
        return 3;
    if ([o isEqualToString:@"oshst"])
        return 2;
    return 0xFFFFFFFFu;
    }

static uint32_t shiftKind(NSString* b)
    {
    if ([b isEqualToString:@"lsl"])
        return 0;
    if ([b isEqualToString:@"lsr"])
        return 1;
    if ([b isEqualToString:@"asr"])
        return 2;
    return 3; // ror
    }

// ── Immediates ────────────────────────────────────────────────────────────
// An ARM data-processing immediate is an 8-bit value rotated RIGHT by an even
// amount. The encoder must FIND the rotation; there is no other way to spell a
// constant in one instruction.
static int encodeImm12(uint32_t v)
    {
    for (uint32_t rot = 0; rot < 16; rot++)
        {
        uint32_t sh = rot * 2;
        uint32_t rotated = sh == 0 ? v : ((v << sh) | (v >> (32 - sh)));
        if (rotated <= 255)
            return (int)((rot << 8) | rotated);
        }
    return -1;
    }

static BOOL isImmediate(NSString* t)
    {
    return t.length > 0 && [t characterAtIndex:0] == '#';
    }

// `#123`, `#0x1F`, `#$1F`, `#-4` — and the SAME forms without the `#`, which
// `movt rD, 22612` really is spelled as. Skipping character 0 unconditionally
// turned that into 2612: a wrong constant, silently assembled.
static uint32_t immediateValue(NSString* t)
    {
    NSUInteger i = (t.length && [t characterAtIndex:0] == '#') ? 1 : 0;
    BOOL neg = NO;
    if (i < t.length && [t characterAtIndex:i] == '-')
        {
        neg = YES;
        i++;
        }
    uint32_t v = 0;
    BOOL hex = NO;
    if (i + 1 < t.length && [t characterAtIndex:i] == '0' && ([t characterAtIndex:i + 1] == 'x' || [t characterAtIndex:i + 1] == 'X'))
        {
        hex = YES;
        i += 2;
        }
    else if (i < t.length && [t characterAtIndex:i] == '$')
        {
        hex = YES;
        i++;
        }
    while (i < t.length)
        {
        unichar c = [t characterAtIndex:i];
        uint32_t d = 16;
        if (c >= '0' && c <= '9')
            d = (uint32_t)(c - '0');
        else if (hex && c >= 'a' && c <= 'f')
            d = (uint32_t)(c - 'a') + 10;
        else if (hex && c >= 'A' && c <= 'F')
            d = (uint32_t)(c - 'A') + 10;
        else
            break;
        v = hex ? (v * 16 + d) : (v * 10 + d);
        i++;
        }
    return neg ? (uint32_t)(0 - v) : v;
    }

static uint32_t decimalValue(NSString* t)
    {
    uint32_t v = 0;
    for (NSUInteger i = 0; i < t.length; i++)
        {
        unichar c = [t characterAtIndex:i];
        if (c < '0' || c > '9')
            break;
        v = v * 10 + (uint32_t)(c - '0');
        }
    return v;
    }

static BOOL isNumericLabel(NSString* n)
    {
    if (!n.length)
        return NO;
    for (NSUInteger i = 0; i < n.length; i++)
        {
        unichar c = [n characterAtIndex:i];
        if (c < '0' || c > '9')
            return NO;
        }
    return YES;
    }

static BOOL isNumericRef(NSString* t)
    {
    if (t.length < 2)
        return NO;
    unichar last = [t characterAtIndex:t.length - 1];
    if (last != 'f' && last != 'b')
        return NO;
    return isNumericLabel([t substringToIndex:t.length - 1]);
    }

static NSString* trimmed(NSString* s)
    {
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    }

// Strip an end-of-line comment, in either spelling the oracle accepts: `@`,
// traditional ARM, and `//`, which is what the licence header on every
// generated runtime .s uses.
//
// NOT `;`. The arm64 assembler cuts on it because clang's arm64 output comments
// that way, but on ARM32 `arm-none-eabi-as` reads `;` as a STATEMENT SEPARATOR —
// `mov r0, #1 ; mov r0, #2` assembles to two instructions — so cutting there
// would delete real code.
//
// Quoted strings are respected: the oracle keeps the `//` in a .asciz of
// "http://example/x", and so must we.
static NSString* stripComment(NSString* l)
    {
    BOOL inStr = NO;
    for (NSUInteger i = 0; i < l.length; i++)
        {
        unichar c = [l characterAtIndex:i];
        if (c == '"')
            {
            inStr = !inStr;
            continue;
            }
        if (inStr)
            continue;
        if (c == '@')
            return [l substringToIndex:i];
        if (c == '/' && i + 1 < l.length && [l characterAtIndex:i + 1] == '/')
            return [l substringToIndex:i];
        }
    return l;
    }

// ── Emission ──────────────────────────────────────────────────────────────
- (void)word:(uint32_t)w
    {
    uint8_t b[4] = {(uint8_t)w, (uint8_t)(w >> 8), (uint8_t)(w >> 16), (uint8_t)(w >> 24)};
    [_text appendBytes:b length:4];
    }

// A raw byte into whichever section is current. Pass 1 only advances the
// cursor; the bytes themselves are pass 2's.
- (void)putByte:(uint32_t)b
    {
    if (_section == 1)
        {
        if (_pass == 2)
            {
            uint8_t v = (uint8_t)b;
            [_text appendBytes:&v length:1];
            }
        _pc++;
        return;
        }
    if (_pass == 2)
        {
        uint8_t v = (uint8_t)b;
        [_data appendBytes:&v length:1];
        }
    _dataPc++;
    }

- (uint32_t)cursor
    {
    return _section == 1 ? _pc : _dataPc;
    }

// `<op>{cond}{s} Rd, Rn, <operand2>` — the shape most of the subset has. A
// comparison writes no destination and always sets the flags; a move reads no
// first operand.
- (void)dataProcessing:(int)cond opcode:(int)opcode setFlags:(BOOL)setFlags
                    rd:(uint32_t)rd
                    rn:(uint32_t)rn
                 imm12:(int)imm12
                    rm:(uint32_t)rm
                  kind:(uint32_t)kind
                amount:(uint32_t)amt
    {
    uint32_t w = ((uint32_t)cond << 28) | ((uint32_t)opcode << 21) | (rn << 16) | (rd << 12);
    if (setFlags)
        w |= (1u << 20);
    if (imm12 >= 0)
        w |= (1u << 25) | (uint32_t)imm12;
    else
        w |= (amt << 7) | (kind << 5) | rm;
    [self word:w];
    }

// `movw`/`movt` — a bare 16-bit immediate, split 4 + 12.
- (void)movImm16:(int)cond top:(BOOL)top rd:(uint32_t)rd imm16:(uint32_t)imm16
    {
    uint32_t op = top ? 0x34u : 0x30u;
    [self word:((uint32_t)cond << 28) | (op << 20) | (((imm16 >> 12) & 0xFu) << 16) | (rd << 12) | (imm16 & 0xFFFu)];
    }

// `<ldr|str>{b} Rt, [Rn, #±off]` — the word/byte form, offset12.
- (void)loadStore:(int)cond load:(BOOL)load byte:(BOOL)byte
               rt:(uint32_t)rt
               rn:(uint32_t)rn
              off:(int)off
    {
    uint32_t up = off >= 0 ? 1u : 0u;
    uint32_t mag = off >= 0 ? (uint32_t)off : (uint32_t)(-off);
    uint32_t w = ((uint32_t)cond << 28) | (1u << 26) | (1u << 24) | (up << 23);
    if (byte)
        w |= (1u << 22);
    if (load)
        w |= (1u << 20);
    [self word:w | (rn << 16) | (rt << 12) | (mag & 0xFFFu)];
    }

// The halfword and signed forms are a different encoding entirely: the offset
// splits 4 + 4 around a fixed nibble.
- (void)loadStoreHalf:(int)cond load:(BOOL)load rt:(uint32_t)rt rn:(uint32_t)rn
                  off:(int)off
               signed:(BOOL)signedOp
             halfword:(BOOL)halfword
    {
    uint32_t up = off >= 0 ? 1u : 0u;
    uint32_t mag = off >= 0 ? (uint32_t)off : (uint32_t)(-off);
    uint32_t w = ((uint32_t)cond << 28) | (1u << 24) | (up << 23) | (1u << 22);
    if (load)
        w |= (1u << 20);
    uint32_t sh = (1u << 5); // H bit
    if (signedOp)
        sh |= (1u << 6); // S bit
    if (signedOp && !halfword)
        sh = (1u << 6); // ldrsb: S set, H clear
    [self word:w | (rn << 16) | (rt << 12) | (((mag >> 4) & 0xFu) << 8) | 0x90u | sh | (mag & 0xFu)];
    }

// `push`/`pop` are the load/store-multiple forms with sp as the base:
// push = stmdb sp!, pop = ldmia sp!.
- (void)pushPop:(int)cond pop:(BOOL)pop regList:(uint32_t)regList
    {
    uint32_t w = ((uint32_t)cond << 28) | (1u << 27) | (1u << 21) | (13u << 16);
    if (pop)
        w |= (1u << 23) | (1u << 20); // U (up) + L (load)
    else
        w |= (1u << 24); // P (pre-decrement)
    [self word:w | regList];
    }

// A branch's immediate is the WORD distance from pc, and pc reads as the
// instruction's address plus eight.
- (void)branch:(int)cond link:(BOOL)link target:(int)targetOffset at:(uint32_t)at
    {
    int delta = (targetOffset - (int)at - 8) >> 2;
    uint32_t w = ((uint32_t)cond << 28) | (5u << 25) | ((uint32_t)delta & 0xFFFFFFu);
    if (link)
        w |= (1u << 24);
    [self word:w];
    }

- (void)branchExchange:(int)cond link:(BOOL)link rm:(uint32_t)rm
    {
    uint32_t op = link ? 3u : 1u;
    [self word:((uint32_t)cond << 28) | 0x12FFF00u | (op << 4) | rm];
    }

// uxtb/uxth/sxtb/sxth with no rotation — the only forms emitted.
- (void)extend:(int)cond sign:(BOOL)sign halfword:(BOOL)halfword
            rd:(uint32_t)rd
            rm:(uint32_t)rm
    {
    uint32_t op = sign ? (halfword ? 0x6Bu : 0x6Au) : (halfword ? 0x6Fu : 0x6Eu);
    [self word:((uint32_t)cond << 28) | (op << 20) | (0xFu << 16) | (rd << 12) | (7u << 4) | rm];
    }

- (void)multiply:(int)cond rd:(uint32_t)rd rm:(uint32_t)rm rs:(uint32_t)rs
    {
    [self word:((uint32_t)cond << 28) | (rd << 16) | (9u << 4) | (rs << 8) | rm];
    }

- (void)multiplyAccumulate:(int)cond rd:(uint32_t)rd rm:(uint32_t)rm
                        rs:(uint32_t)rs
                        rn:(uint32_t)rn
    {
    [self word:((uint32_t)cond << 28) | (1u << 21) | (rd << 16) | (rn << 12) | (rs << 8) | (9u << 4) | rm];
    }

// ── Assembling a file ─────────────────────────────────────────────────────
// Two passes: the first places every label, the second encodes. A branch has to
// know where it is going before it can be encoded, and forward branches are the
// common case.
- (nullable NSData*)assemble:(NSString*)source error:(NSError**)error
    {
    _lines = [source componentsSeparatedByString:@"\n"];
    _labels = [NSMutableDictionary dictionary];
    _numeric = [NSMutableDictionary dictionary];
    _syms = [NSMutableArray array];
    _relocs = [NSMutableArray array];
    _missing = nil;
    _failWhy = nil;

    _pass = 1;
    [self run];
    _pass = 2;
    [self run];

    if (_failWhy)
        {
        if (error)
            *error = [NSError errorWithDomain:@"XAArm32Assembler"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:
                                                                                          @"unsupported ARM assembly: %@%@", _failWhy,
                                                                                          _missing.count > 1
                                                                                              ? [NSString stringWithFormat:@" (also: %@)",
                                                                                                                           [[_missing subarrayWithRange:NSMakeRange(1, _missing.count - 1)]
                                                                                                                               componentsJoinedByString:@", "]]
                                                                                              : @""]}];
        return nil;
        }
    return _text;
    }

- (void)run
    {
    _text = [NSMutableData data];
    _data = [NSMutableData data];
    _section = 1;
    _pc = 0;
    _dataPc = 0;
    _pool = [NSMutableArray array];
    _poolSites = [NSMutableArray array];
    if (_pass == 2)
        _relocs = [NSMutableArray array];
    for (NSString* raw in _lines)
        [self line:trimmed(raw)];
    [self flushPool];
    }

- (void)line:(NSString*)text
    {
    if (!text.length)
        return;
    // A trailing comment. The back end never emits one, but the runtime written
    // BY HAND does, and an operand with a comment glued to it parses as a bad
    // register — which the assembler then reports as an unknown mnemonic,
    // pointing at the wrong thing entirely.
    //
    // Both spellings, because the oracle takes both: `@` is traditional ARM and
    // `//` is what the licence header on every generated runtime .s uses. While
    // only `@` was cut, every arm9 self-host link died on the first line of
    // rtgen-arm9.s with `unsupported ARM assembly: //`.
    //
    // Quoted strings are respected, so a `//` inside a .asciz survives.
    text = trimmed(stripComment(text));
    if (!text.length)
        return;
    // `label: instruction` on one line — likewise a hand-written form. The
    // label is defined and the rest of the line assembles as usual.
    NSRange colon = [text rangeOfString:@":"];
    if (colon.location != NSNotFound && colon.location + 1 < text.length)
        {
        NSString* head = [text substringToIndex:colon.location + 1];
        NSString* tail = trimmed([text substringFromIndex:colon.location + 1]);
        NSString* l = labelOn(head);
        if (l && tail.length)
            {
            [self defineLabel:l];
            text = tail;
            }
        }
    NSString* lab = labelOn(text);
    if (lab)
        {
        [self defineLabel:lab];
        return;
        }
    unichar c0 = [text characterAtIndex:0];
    if (c0 == '@')
        return; // a whole-line comment
    if (c0 == '/' && text.length > 1 && [text characterAtIndex:1] == '/')
        return; // likewise, in the `//` spelling
    if (c0 == '.')
        {
        [self directive:text];
        return;
        }
    if (_section != 1)
        return; // no instructions in .data
    if (_pass == 1)
        {
        // Pass 1 does not encode, but it must see a `ldr =sym`: the pool word it
        // needs occupies space, and everything after the pool shifts by it. It
        // must also see every symbol a relocation will name, because the table
        // those indices point into is built here.
        [self notePoolUse:text];
        [self noteSymbolUse:text];
        _pc += 4;
        return;
        }
    [self instruction:text];
    _pc += 4;
    }

// A label definition is a bare name followed by `:`.
static NSString* labelOn(NSString* line)
    {
    if (!line.length)
        return nil;
    if ([line characterAtIndex:line.length - 1] != ':')
        return nil;
    NSString* name = [line substringToIndex:line.length - 1];
    if (!name.length)
        return nil;
    for (NSUInteger i = 0; i < name.length; i++)
        {
        unichar c = [name characterAtIndex:i];
        BOOL ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '.' || c == '$';
        if (!ok)
            return nil;
        }
    return name;
    }

// Pass 1's view of `ldr rX, =sym`: remember that this pool will need a word, so
// its size is known before any label after it is placed.
- (void)notePoolUse:(NSString*)text
    {
    NSRange eq = [text rangeOfString:@"="];
    if (eq.location == NSNotFound)
        return;
    if (![text hasPrefix:@"ldr"])
        return;
    [_pool addObject:trimmed([text substringFromIndex:eq.location + 1])];
    [_poolSites addObject:@(_pc)];
    }

// A `bl <name>` or `ldr rX, =<name>` names a symbol the relocation will need an
// index for — even one this file never defines.
- (void)noteSymbolUse:(NSString*)text
    {
    NSUInteger sp = 0;
    while (sp < text.length && [text characterAtIndex:sp] != ' ' && [text characterAtIndex:sp] != '\t')
        sp++;
    NSString* m = [text substringToIndex:sp];
    NSString* rest = trimmed([text substringFromIndex:sp]);
    if ([m isEqualToString:@"bl"] || [m isEqualToString:@"b"])
        {
        if (!rest.length)
            return;
        if ([rest hasPrefix:@".L"])
            return;
        if (isNumericRef(rest))
            return;
        [self symbolFor:rest];
        return;
        }
    NSRange eq = [text rangeOfString:@"="];
    if (eq.location != NSNotFound && [m hasPrefix:@"ldr"])
        [self symbolFor:trimmed([text substringFromIndex:eq.location + 1])];
    }

- (void)defineLabel:(NSString*)name
    {
    if (_pass != 1)
        return;
    if (isNumericLabel(name))
        {
        NSMutableArray<NSNumber*>* list = _numeric[name];
        if (!list)
            {
            list = [NSMutableArray array];
            _numeric[name] = list;
            }
        [list addObject:@([self cursor])];
        return;
        }
    _labels[name] = @([self cursor]);
    // A `.L` label is assembler-internal and does not belong in the symbol
    // table — UNLESS something took its address (`.word .LANCHOR0+16`, which is
    // how a compiler names its own static data). Then the relocation needs a
    // symbol to point at, so the one already created by that reference is
    // given its position here.
    if ([name hasPrefix:@".L"])
        {
        // Recorded whether or not anything has referenced it YET: a `.word
        // .LANCHOR0+16` that appears AFTER the label would otherwise create a
        // fresh undefined symbol, and the link fails on a name that is defined
        // four lines above it.
        XAArm32Symbol* l = [self symbolFor:name];
        l.section = _section;
        l.value = [self cursor];
        return;
        }
    XAArm32Symbol* sym = [self symbolFor:name];
    sym.section = _section;
    sym.value = [self cursor];
    }

// `1f` / `1b` — the nearest definition of that number in the named direction.
// -1 when there is none, which is a malformed file.
- (int)numericTarget:(NSString*)ref
    {
    if (ref.length < 2)
        return -1;
    unichar dir = [ref characterAtIndex:ref.length - 1];
    if (dir != 'f' && dir != 'b')
        return -1;
    NSString* num = [ref substringToIndex:ref.length - 1];
    if (!isNumericLabel(num))
        return -1;
    NSArray<NSNumber*>* list = _numeric[num];
    if (!list)
        return -1;
    int best = -1;
    for (NSNumber* n in list)
        {
        uint32_t at = n.unsignedIntValue;
        if (dir == 'f')
            {
            if (at > _pc && best < 0)
                best = (int)at;
            }
        else if (at <= _pc)
            best = (int)at;
        }
    return best;
    }

// The symbol table is built in pass 1 and read in pass 2, so a `.global` that
// FOLLOWS the label it names still applies.
- (BOOL)isGlobalName:(NSString*)name
    {
    for (XAArm32Symbol* s in _syms)
        if ([s.name isEqualToString:name])
            return s.isGlobal;
    return NO;
    }

- (XAArm32Symbol*)symbolFor:(NSString*)name
    {
    for (XAArm32Symbol* s in _syms)
        if ([s.name isEqualToString:name])
            return s;
    XAArm32Symbol* s = [XAArm32Symbol new];
    s.name = name;
    [_syms addObject:s];
    return s;
    }

// ── Directives ────────────────────────────────────────────────────────────
- (void)directive:(NSString*)text
    {
    NSUInteger sp = 0;
    while (sp < text.length && [text characterAtIndex:sp] != ' ' && [text characterAtIndex:sp] != '\t')
        sp++;
    NSString* d = [text substringToIndex:sp];
    NSString* rest = trimmed([text substringFromIndex:sp]);
    if ([d isEqualToString:@".text"])
        {
        _section = 1;
        return;
        }
    if ([d isEqualToString:@".data"])
        {
        _section = 2;
        return;
        }
    if ([d isEqualToString:@".bss"])
        {
        _section = 2;
        return;
        }
    if ([d isEqualToString:@".section"])
        {
        // The NAME decides, not the directive. `.section .text.startup` is CODE,
        // and reading it as data put `main` in the writable segment — where the
        // loader jumped, and the image took a prefetch abort at its own base.
        NSString* nm = rest;
        NSRange comma = [nm rangeOfString:@","];
        if (comma.location != NSNotFound)
            nm = trimmed([nm substringToIndex:comma.location]);
        _section = [nm hasPrefix:@".text"] ? 1 : 2;
        return;
        }
    if ([d isEqualToString:@".ltorg"])
        {
        [self flushPool];
        return;
        }
    if ([d isEqualToString:@".global"] || [d isEqualToString:@".globl"])
        {
        if (_pass == 1)
            [self symbolFor:rest].isGlobal = YES;
        return;
        }
    if ([d isEqualToString:@".hidden"])
        {
        if (_pass == 1)
            [self symbolFor:rest].hidden = YES;
        return;
        }
    if ([d isEqualToString:@".type"])
        {
        [self typeDirective:rest];
        return;
        }
    // computed by the writer
    if ([d isEqualToString:@".size"])
        {
        return;
        }
    if ([d isEqualToString:@".comm"])
        {
        [self commDirective:rest];
        return;
        }
    if ([d isEqualToString:@".byte"])
        {
        [self emitByte:rest];
        return;
        }
    if ([d isEqualToString:@".word"])
        {
        [self emitWord:rest];
        return;
        }
    if ([d isEqualToString:@".p2align"])
        {
        [self align:rest];
        return;
        }
    if ([d isEqualToString:@".set"] || [d isEqualToString:@".equ"])
        {
        [self setDirective:rest];
        return;
        }
    if ([d isEqualToString:@".zero"] || [d isEqualToString:@".space"])
        {
        uint32_t n = decimalValue(rest);
        for (uint32_t i = 0; i < n; i++)
            [self putByte:0];
        return;
        }
    // .file/.syntax/.arch/.fpu/.incbin and friends carry no payload here.
    }

// `.set name, . + 0` — how a compiler names an anchor into its own data. Only
// the location-relative form is understood; anything else is REPORTED, because
// a `.set` quietly ignored is a symbol that resolves to zero at run time.
- (void)setDirective:(NSString*)rest
    {
    NSRange comma = [rest rangeOfString:@","];
    if (comma.location == NSNotFound)
        {
        [self giveUp:@".set (no value)"];
        return;
        }
    NSString* name = trimmed([rest substringToIndex:comma.location]);
    NSString* val = trimmed([rest substringFromIndex:comma.location + 1]);
    if (![val hasPrefix:@"."])
        {
        [self giveUp:[@".set " stringByAppendingString:val]];
        return;
        }
    uint32_t extra = 0;
    NSRange plus = [val rangeOfString:@"+"];
    if (plus.location != NSNotFound)
        extra = immediateValue(trimmed([val substringFromIndex:plus.location + 1]));
    if (_pass != 1)
        return;
    _labels[name] = @([self cursor] + extra);
    XAArm32Symbol* sym = [self symbolFor:name];
    sym.section = _section;
    sym.value = [self cursor] + extra;
    }

- (void)typeDirective:(NSString*)rest
    {
    if (_pass != 1)
        return;
    NSRange comma = [rest rangeOfString:@","];
    if (comma.location == NSNotFound)
        return;
    NSString* name = trimmed([rest substringToIndex:comma.location]);
    NSString* kind = [rest substringFromIndex:comma.location + 1];
    if ([kind rangeOfString:@"function"].location != NSNotFound)
        [self symbolFor:name].isFunction = YES;
    }

// `.comm name, size, align` — a zero-filled global that the linker places.
- (void)commDirective:(NSString*)rest
    {
    if (_pass != 1)
        return;
    NSArray<NSString*>* parts = [rest componentsSeparatedByString:@","];
    if (!parts.count)
        return;
    XAArm32Symbol* s = [self symbolFor:trimmed(parts[0])];
    s.section = 3; // COMMON
    s.isGlobal = YES;
    if (parts.count > 1)
        s.size = decimalValue(trimmed(parts[1]));
    s.value = 4; // a COMMON's value is its alignment
    }

- (void)emitByte:(NSString*)rest
    {
    for (NSString* p in [rest componentsSeparatedByString:@","])
        [self putByte:immediateValue([@"#" stringByAppendingString:trimmed(p)])];
    }

// `.word 0` is a literal; `.word symbol` is a relocation against it, and
// `.word symbol+16` is one with an ADDEND — which an ARM REL relocation carries
// in the word itself, so the offset is written and the linker adds the symbol.
- (void)emitWord:(NSString*)rest
    {
    for (NSString* raw in [rest componentsSeparatedByString:@","])
        {
        NSString* t = trimmed(raw);
        if (t.length && [t characterAtIndex:0] >= '0' && [t characterAtIndex:0] <= '9')
            {
            uint32_t v = immediateValue(t);
            [self putByte:v];
            [self putByte:v >> 8];
            [self putByte:v >> 16];
            [self putByte:v >> 24];
            continue;
            }
        NSString* name = t;
        uint32_t addend = 0;
        NSRange plus = [t rangeOfString:@"+"];
        if (plus.location != NSNotFound)
            {
            name = trimmed([t substringToIndex:plus.location]);
            addend = immediateValue(trimmed([t substringFromIndex:plus.location + 1]));
            }
        if (_pass == 2)
            {
            XAArm32Reloc* r = [XAArm32Reloc new];
            r.section = _section;
            r.offset = [self cursor];
            r.symbol = name;
            r.kind = XAArm32RelocAbs32;
            [_relocs addObject:r];
            }
        if (_pass == 1)
            [self symbolFor:name];
        [self putByte:addend];
        [self putByte:addend >> 8];
        [self putByte:addend >> 16];
        [self putByte:addend >> 24];
        }
    }

- (void)align:(NSString*)rest
    {
    uint32_t p = decimalValue(rest);
    uint32_t mask = (1u << p) - 1u;
    while (([self cursor] & mask) != 0)
        [self putByte:0];
    }

// ── The literal pool ──────────────────────────────────────────────────────
// `ldr rX, =sym` becomes a pc-relative load of a word that holds the symbol's
// address. The word goes in the next pool — which is what `.ltorg` marks — and
// carries the relocation.
- (void)flushPool
    {
    if (!_pool.count)
        return;
    if (_section != 1)
        {
        _pool = [NSMutableArray array];
        _poolSites = [NSMutableArray array];
        return;
        }
    for (NSUInteger i = 0; i < _pool.count; i++)
        {
        NSString* sym = _pool[i];
        uint32_t site = _poolSites[i].unsignedIntValue;
        if (_pass == 2)
            {
            // Patch the ldr's 12-bit offset: pool word minus (site + 8).
            uint32_t disp = _pc - (site + 8);
            uint8_t* p = (uint8_t*)_text.mutableBytes + site;
            uint32_t w = p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
            w = (w & ~0xFFFu) | (disp & 0xFFFu);
            p[0] = (uint8_t)w;
            p[1] = (uint8_t)(w >> 8);
            p[2] = (uint8_t)(w >> 16);
            p[3] = (uint8_t)(w >> 24);
            XAArm32Reloc* r = [XAArm32Reloc new];
            r.section = 1;
            r.offset = _pc;
            r.symbol = sym;
            r.kind = XAArm32RelocAbs32;
            [_relocs addObject:r];
            }
        [self putByte:0];
        [self putByte:0];
        [self putByte:0];
        [self putByte:0];
        }
    _pool = [NSMutableArray array];
    _poolSites = [NSMutableArray array];
    }

// ── One instruction ───────────────────────────────────────────────────────
- (void)instruction:(NSString*)line
    {
    NSUInteger sp = 0;
    while (sp < line.length && [line characterAtIndex:sp] != ' ' && [line characterAtIndex:sp] != '\t')
        sp++;
    NSString* mnem = [line substringToIndex:sp];
    NSArray<NSString*>* ops = splitOperands(trimmed([line substringFromIndex:sp]));
    [self encode:mnem ops:ops];
    }

// Operands split on commas that are NOT inside brackets — `[r0, #4]` and
// `{r4-r11, lr}` are each one operand.
static NSArray<NSString*>* splitOperands(NSString* rest)
    {
    NSMutableArray<NSString*>* out = [NSMutableArray array];
    NSInteger depth = 0;
    NSUInteger start = 0;
    for (NSUInteger i = 0; i <= rest.length; i++)
        {
        if (i == rest.length)
            {
            if (i > start)
                [out addObject:trimmed([rest substringWithRange:NSMakeRange(start, i - start)])];
            break;
            }
        unichar c = [rest characterAtIndex:i];
        if (c == '[' || c == '{')
            depth++;
        else if (c == ']' || c == '}')
            depth--;
        else if (c == ',' && depth == 0)
            {
            [out addObject:trimmed([rest substringWithRange:NSMakeRange(start, i - start)])];
            start = i + 1;
            }
        }
    return out;
    }

// Split a mnemonic into base + condition suffix: `moveq` is `mov` + `eq`, `subs`
// is `sub` with the flag bit. The base is the longest match that leaves a valid
// suffix.
- (BOOL)splitMnemonic:(NSString*)m
    {
    _setFlags = NO;
    _cond = 14;
    _base = m;
    if (dpOpcode(m) >= 0 || isKnownBase(m))
        return YES;
    if (m.length > 1 && [m characterAtIndex:m.length - 1] == 's')
        {
        NSString* b = [m substringToIndex:m.length - 1];
        // The shift mnemonics take an S too (`lsls`), and so does `umulls`;
        // they are not data-processing opcodes, so isKnownBase has to be asked.
        if (dpOpcode(b) >= 0 || isShiftOp(b) || [b isEqualToString:@"umull"] || [b isEqualToString:@"smull"])
            {
            _base = b;
            _setFlags = YES;
            return YES;
            }
        }
    if (m.length > 2)
        {
        NSString* c = [m substringFromIndex:m.length - 2];
        NSString* b = [m substringToIndex:m.length - 2];
        int cc = condCode(c);
        if (cc >= 0 && (dpOpcode(b) >= 0 || isKnownBase(b)))
            {
            _base = b;
            _cond = cc;
            return YES;
            }
        }
    return NO;
    }

- (void)encode:(NSString*)mnem ops:(NSArray<NSString*>*)ops
    {
    // A `v`-prefixed mnemonic is floating point and has its own shape — its
    // suffixes are precisions, not conditions, so it must not go through the
    // condition-suffix split.
    if (mnem.length && [mnem characterAtIndex:0] == 'v')
        {
        if (![self encodeVfp:mnem ops:ops])
            [self giveUp:mnem];
        return;
        }
    if (![self splitMnemonic:mnem])
        {
        [self giveUp:mnem];
        return;
        }
    NSString* b = _base;
    if ([b isEqualToString:@"push"] || [b isEqualToString:@"pop"])
        {
        BOOL pop = [b isEqualToString:@"pop"];
        uint32_t list = registerList(ops);
        // ONE register is a plain store/load with writeback, not a
        // load/store-multiple — which is what `as` emits, and the ARM ARM's
        // preferred encoding.
        if (list && (list & (list - 1)) == 0)
            {
            uint32_t r = 0;
            while (!((list >> r) & 1u))
                r++;
            [self word:((uint32_t)_cond << 28) | (pop ? 0x49D0004u : 0x52D0004u) | (r << 12)];
            return;
            }
        [self pushPop:_cond pop:pop regList:list];
        return;
        }
    if ([b isEqualToString:@"b"] || [b isEqualToString:@"bl"])
        {
        [self encodeBranch:[b isEqualToString:@"bl"] ops:ops];
        return;
        }
    if ([b isEqualToString:@"bx"] || [b isEqualToString:@"blx"])
        {
        int rm = ops.count ? regNumber(ops[0]) : -1;
        if (rm < 0)
            {
            [self giveUp:mnem];
            return;
            }
        [self branchExchange:_cond link:[b isEqualToString:@"blx"] rm:(uint32_t)rm];
        return;
        }
    if ([b isEqualToString:@"movw"] || [b isEqualToString:@"movt"])
        {
        if (ops.count < 2)
            {
            [self giveUp:mnem];
            return;
            }
        int rd = regNumber(ops[0]);
        if (rd < 0)
            {
            [self giveUp:mnem];
            return;
            }
        [self movImm16:_cond
                   top:[b isEqualToString:@"movt"]
                    rd:(uint32_t)rd
                 imm16:immediateValue(ops[1]) & 0xFFFFu];
        return;
        }
    if (isExtendOp(b))
        {
        if (ops.count < 2)
            {
            [self giveUp:mnem];
            return;
            }
        int rd = regNumber(ops[0]), rm = regNumber(ops[1]);
        if (rd < 0 || rm < 0)
            {
            [self giveUp:mnem];
            return;
            }
        [self extend:_cond
                sign:([b characterAtIndex:0] == 's')
            halfword:([b isEqualToString:@"uxth"] || [b isEqualToString:@"sxth"])
                  rd:(uint32_t)rd
                  rm:(uint32_t)rm];
        return;
        }
    if ([b isEqualToString:@"mul"])
        {
        if (ops.count < 3)
            {
            [self giveUp:mnem];
            return;
            }
        int rd = regNumber(ops[0]), rm = regNumber(ops[1]), rs = regNumber(ops[2]);
        if (rd < 0 || rm < 0 || rs < 0)
            {
            [self giveUp:mnem];
            return;
            }
        [self multiply:_cond rd:(uint32_t)rd rm:(uint32_t)rm rs:(uint32_t)rs];
        return;
        }
    // `umull rdLo, rdHi, rn, rm` — the 64-bit product of two 32-bit registers,
    // which is what a 64-bit multiply is built from.
    if ([b isEqualToString:@"umull"] || [b isEqualToString:@"smull"])
        {
        if (ops.count < 4)
            {
            [self giveUp:mnem];
            return;
            }
        int rdlo = regNumber(ops[0]), rdhi = regNumber(ops[1]);
        int rn = regNumber(ops[2]), rm = regNumber(ops[3]);
        if (rdlo < 0 || rdhi < 0 || rn < 0 || rm < 0)
            {
            [self giveUp:mnem];
            return;
            }
        uint32_t op = [b isEqualToString:@"smull"] ? 6u : 4u; // bits 23-21
        [self word:((uint32_t)_cond << 28) | (op << 21) | (_setFlags ? (1u << 20) : 0u) | ((uint32_t)rdhi << 16) | ((uint32_t)rdlo << 12) | ((uint32_t)rm << 8) | (9u << 4) | (uint32_t)rn];
        return;
        }
    if ([b isEqualToString:@"mla"])
        {
        if (ops.count < 4)
            {
            [self giveUp:mnem];
            return;
            }
        int rd = regNumber(ops[0]), rm = regNumber(ops[1]);
        int rs = regNumber(ops[2]), rn = regNumber(ops[3]);
        if (rd < 0 || rm < 0 || rs < 0 || rn < 0)
            {
            [self giveUp:mnem];
            return;
            }
        [self multiplyAccumulate:_cond
                              rd:(uint32_t)rd
                              rm:(uint32_t)rm
                              rs:(uint32_t)rs
                              rn:(uint32_t)rn];
        return;
        }
    if ([b isEqualToString:@"svc"] || [b isEqualToString:@"swi"])
        {
        // A supervisor call: the 24-bit comment field is what the kernel's
        // dispatcher ignores (the number is in r7), but it is encoded.
        uint32_t imm = ops.count ? immediateValue(ops[0]) : 0;
        [self word:((uint32_t)_cond << 28) | (0xFu << 24) | (imm & 0xFFFFFFu)];
        return;
        }
    if ([b isEqualToString:@"udf"])
        {
        [self word:0xE7F000F0u]; // permanently undefined = a trap
        return;
        }
    if ([b isEqualToString:@"clz"])
        {
        if (ops.count < 2)
            {
            [self giveUp:mnem];
            return;
            }
        int rd = regNumber(ops[0]), rm = regNumber(ops[1]);
        if (rd < 0 || rm < 0)
            {
            [self giveUp:mnem];
            return;
            }
        [self word:((uint32_t)_cond << 28) | 0x16F0F10u | ((uint32_t)rd << 12) | (uint32_t)rm];
        return;
        }
    if ([b isEqualToString:@"clrex"])
        {
        [self word:0xF57FF01Fu];
        return;
        }
    // `ldrd r4, r5, [rN, #off]` — a register PAIR, named by its first register;
    // the offset splits 4+4 around a fixed nibble as the halfword forms do.
    if ([b isEqualToString:@"ldrd"] || [b isEqualToString:@"strd"])
        {
        BOOL ld = [b isEqualToString:@"ldrd"];
        if (ops.count < 2)
            {
            [self giveUp:mnem];
            return;
            }
        int rt = regNumber(ops[0]);
        // The second register is implicit (rt+1); `as` accepts it spelled or not.
        NSString* addr = ops[ops.count - 1];
        if (rt < 0 || ![addr hasPrefix:@"["] || ![addr hasSuffix:@"]"])
            {
            [self giveUp:mnem];
            return;
            }
        NSArray<NSString*>* parts =
            splitOperands([addr substringWithRange:NSMakeRange(1, addr.length - 2)]);
        if (!parts.count)
            {
            [self giveUp:mnem];
            return;
            }
        int rn = regNumber(trimmed(parts[0]));
        if (rn < 0)
            {
            [self giveUp:mnem];
            return;
            }
        int off = 0;
        if (parts.count > 1)
            {
            NSString* o = trimmed(parts[1]);
            if (!isImmediate(o))
                {
                [self giveUp:mnem];
                return;
                }
            off = (int)immediateValue(o);
            }
        uint32_t up = off >= 0 ? 1u : 0u;
        uint32_t mag = off >= 0 ? (uint32_t)off : (uint32_t)(-off);
        [self word:((uint32_t)_cond << 28) | (1u << 24) | (up << 23) | (1u << 22) | ((uint32_t)rn << 16) | ((uint32_t)rt << 12) | (((mag >> 4) & 0xFu) << 8) | (ld ? 0xD0u : 0xF0u) | (mag & 0xFu)];
        return;
        }
    // `mrc p15, 0, r0, c13, c0, 3` — read a coprocessor register. The thread
    // pointer lives behind one of these, which is why a runtime needs it.
    if ([b isEqualToString:@"mrc"] || [b isEqualToString:@"mcr"])
        {
        if (ops.count < 6)
            {
            [self giveUp:mnem];
            return;
            }
        uint32_t cp = decimalValue([ops[0] hasPrefix:@"p"] ? [ops[0] substringFromIndex:1] : ops[0]);
        uint32_t op1 = decimalValue(ops[1]);
        int rt = regNumber(ops[2]);
        uint32_t crn = decimalValue([ops[3] hasPrefix:@"c"] ? [ops[3] substringFromIndex:1] : ops[3]);
        uint32_t crm = decimalValue([ops[4] hasPrefix:@"c"] ? [ops[4] substringFromIndex:1] : ops[4]);
        uint32_t op2 = decimalValue(ops[5]);
        if (rt < 0)
            {
            [self giveUp:mnem];
            return;
            }
        [self word:((uint32_t)_cond << 28) | (0xEu << 24) | (op1 << 21) | (([b isEqualToString:@"mrc"] ? 1u : 0u) << 20) | (crn << 16) | ((uint32_t)rt << 12) | (cp << 8) | (op2 << 5) | (1u << 4) | crm];
        return;
        }
    // A memory barrier. The option is a name, not a number: `ish` is the inner
    // shareable domain, which is what an SMP atomic needs.
    if ([b isEqualToString:@"dmb"] || [b isEqualToString:@"dsb"] || [b isEqualToString:@"isb"])
        {
        uint32_t opt = ops.count ? barrierOption(ops[0]) : 15;
        if (opt == 0xFFFFFFFFu)
            {
            [self giveUp:[NSString stringWithFormat:@"%@ %@", b, ops[0]]];
            return;
            }
        uint32_t kind = [b isEqualToString:@"dmb"] ? 0x50u
                                                   : ([b isEqualToString:@"dsb"] ? 0x40u : 0x60u);
        [self word:0xF57FF000u | kind | opt];
        return;
        }
    // The exclusive pair, which is what an atomic read-modify-write is built
    // from: `ldrexh rT, [rN]` and `strexh rD, rT, [rN]` — note the operand order,
    // the STATUS register comes first on the store.
    if ([b hasPrefix:@"ldrex"] || [b hasPrefix:@"strex"])
        {
        BOOL load = [b characterAtIndex:0] == 'l';
        NSString* width = [b substringFromIndex:5]; // "", "b" or "h"
        uint32_t sizeBits;
        if (!width.length)
            sizeBits = 0x00u; // word
        else if ([width isEqualToString:@"d"])
            {
            [self giveUp:mnem];
            return;
            }
        else if ([width isEqualToString:@"b"])
            sizeBits = 0x04u;
        else if ([width isEqualToString:@"h"])
            sizeBits = 0x06u;
        else
            {
            [self giveUp:mnem];
            return;
            }
        NSUInteger addrIdx = load ? 1 : 2;
        if (ops.count < addrIdx + 1)
            {
            [self giveUp:mnem];
            return;
            }
        NSString* addr = ops[addrIdx];
        if (![addr hasPrefix:@"["] || ![addr hasSuffix:@"]"])
            {
            [self giveUp:mnem];
            return;
            }
        int rn = regNumber(trimmed([addr substringWithRange:NSMakeRange(1, addr.length - 2)]));
        int r0 = regNumber(ops[0]);
        if (rn < 0 || r0 < 0)
            {
            [self giveUp:mnem];
            return;
            }
        if (load)
            {
            //   cond 0001 1 size 1 Rn Rt 1111 1001 1111
            [self word:((uint32_t)_cond << 28) | 0x1900000u | (sizeBits << 20) | ((uint32_t)rn << 16) | ((uint32_t)r0 << 12) | 0xF9Fu];
            return;
            }
        int rt = regNumber(ops[1]);
        if (rt < 0)
            {
            [self giveUp:mnem];
            return;
            }
        //   cond 0001 1 size 0 Rn Rd 1111 1001 Rt
        [self word:((uint32_t)_cond << 28) | 0x1800000u | (sizeBits << 20) | ((uint32_t)rn << 16) | ((uint32_t)r0 << 12) | 0xF90u | (uint32_t)rt];
        return;
        }
    if (isMemOp(b))
        {
        [self encodeMemory:b ops:ops mnem:mnem];
        return;
        }
    if (isShiftOp(b))
        {
        [self encodeShift:b ops:ops mnem:mnem];
        return;
        }
    int dp = dpOpcode(b);
    if (dp >= 0)
        {
        [self encodeDataProcessing:dp ops:ops mnem:mnem];
        return;
        }
    [self giveUp:mnem];
    }

// `{r4-r11, lr}` -> the 16-bit register mask. The braces make the whole list ONE
// operand (the commas inside are not separators), so the items are split here
// rather than by the operand splitter.
static uint32_t registerList(NSArray<NSString*>* ops)
    {
    NSString* inner = [ops componentsJoinedByString:@","];
    while (inner.length && ([inner characterAtIndex:0] == '{' || [inner characterAtIndex:0] == ' '))
        inner = [inner substringFromIndex:1];
    while (inner.length && ([inner characterAtIndex:inner.length - 1] == '}' || [inner characterAtIndex:inner.length - 1] == ' '))
        inner = [inner substringToIndex:inner.length - 1];
    uint32_t mask = 0;
    for (NSString* raw in [inner componentsSeparatedByString:@","])
        {
        NSString* t = trimmed(raw);
        if (!t.length)
            continue;
        NSRange dash = [t rangeOfString:@"-"];
        if (dash.location != NSNotFound)
            {
            int lo = regNumber(trimmed([t substringToIndex:dash.location]));
            int hi = regNumber(trimmed([t substringFromIndex:dash.location + 1]));
            if (lo < 0 || hi < 0)
                continue;
            for (int r = lo; r <= hi; r++)
                mask |= (1u << (uint32_t)r);
            continue;
            }
        int r = regNumber(t);
        if (r >= 0)
            mask |= (1u << (uint32_t)r);
        }
    return mask;
    }

- (void)encodeBranch:(BOOL)link ops:(NSArray<NSString*>*)ops
    {
    if (!ops.count)
        {
        [self giveUp:@"b <nothing>"];
        return;
        }
    NSString* target = ops[0];
    int numeric = [self numericTarget:target];
    if (numeric >= 0)
        {
        [self branch:_cond link:link target:numeric at:_pc];
        return;
        }
    NSNumber* at = _labels[target];
    // A label this file defines resolves here — UNLESS it is global. A global
    // symbol can be preempted at link time, so baking a displacement in is not
    // the assembler's decision to make, and `as` relocates those too (which is
    // how the byte comparison found it).
    if (at && ![self isGlobalName:target])
        {
        [self branch:_cond link:link target:(int)at.unsignedIntValue at:_pc];
        return;
        }
    // A branch to a symbol this file does not define is a RELOCATION. The addend
    // an ARM REL relocation carries lives IN the instruction, and for a call it
    // is -8: the displacement that branches to the instruction itself, which is
    // what the linker adds its own offset to.
    XAArm32Reloc* r = [XAArm32Reloc new];
    r.section = 1;
    r.offset = _pc;
    r.symbol = target;
    r.kind = XAArm32RelocCall;
    [_relocs addObject:r];
    [self branch:_cond link:link target:(int)_pc at:_pc];
    }

// `ldr rD, [rN]` / `[rN, #off]` — the only addressing forms the back end emits.
// `ldr rD, =sym` is a literal-pool load and needs the pool, which belongs with
// relocations.
- (void)encodeMemory:(NSString*)b ops:(NSArray<NSString*>*)ops mnem:(NSString*)mnem
    {
    if (ops.count < 2)
        {
        [self giveUp:mnem];
        return;
        }
    int rt = regNumber(ops[0]);
    NSString* addr = ops[1];
    if (rt < 0)
        {
        [self giveUp:mnem];
        return;
        }
    if (addr.length && [addr characterAtIndex:0] == '=')
        {
        NSString* sym = trimmed([addr substringFromIndex:1]);
        [_pool addObject:sym];
        [_poolSites addObject:@(_pc)];
        // `ldr rT, [pc, #0]` — pc is r15, and the displacement is filled in when
        // the pool is flushed, because only then is the distance known.
        [self loadStore:_cond load:YES byte:NO rt:(uint32_t)rt rn:15 off:0];
        return;
        }
    // `ldr r0, .L9+4` — a PC-relative load from a LABEL, which is how a
    // compiler addresses its own constant pool. The displacement is measured
    // from pc, which reads as this instruction's address plus eight.
    if (addr.length && [addr characterAtIndex:0] != '[')
        {
        NSString* name = addr;
        int extra = 0;
        NSRange plus = [addr rangeOfString:@"+"];
        if (plus.location != NSNotFound)
            {
            name = trimmed([addr substringToIndex:plus.location]);
            extra = (int)decimalValue(trimmed([addr substringFromIndex:plus.location + 1]));
            }
        NSNumber* at = _labels[name];
        if (!at)
            {
            [self giveUp:mnem];
            return;
            }
        int disp = (int)at.unsignedIntValue + extra - (int)_pc - 8;
        BOOL byteOp = [b isEqualToString:@"ldrb"] || [b isEqualToString:@"strb"];
        if (![b isEqualToString:@"ldr"] && !byteOp)
            {
            [self giveUp:mnem];
            return;
            }
        [self loadStore:_cond load:YES byte:byteOp rt:(uint32_t)rt rn:15 off:disp];
        return;
        }
    if (addr.length < 2 || [addr characterAtIndex:0] != '[')
        {
        [self giveUp:mnem];
        return;
        }
    // `[rN, …]!` is pre-indexed with writeback; `[rN], #off` is post-indexed —
    // the bracket closes before the offset. Both appear in compiler output and
    // in any hand-written loop that walks a pointer.
    BOOL writeback = NO, postIndexed = NO;
    if ([addr hasSuffix:@"!"])
        {
        writeback = YES;
        addr = [addr substringToIndex:addr.length - 1];
        }
    NSString* inner;
    NSString* postOff = nil;
    NSRange rb = [addr rangeOfString:@"]"];
    if (rb.location == NSNotFound)
        {
        [self giveUp:mnem];
        return;
        }
    inner = [addr substringWithRange:NSMakeRange(1, rb.location - 1)];
    if (rb.location + 1 < addr.length)
        {
        postIndexed = YES;
        NSString* tail = trimmed([addr substringFromIndex:rb.location + 1]);
        if ([tail hasPrefix:@","])
            tail = trimmed([tail substringFromIndex:1]);
        postOff = tail;
        }
    else if (ops.count > 2)
        {
        // `ldr lr, [ip], #4` — the bracket CLOSES before the comma, so the
        // offset is a separate operand rather than part of the address. It has
        // to be picked up here, or the instruction silently assembles as a
        // plain `[ip]` load and the pointer never advances.
        postIndexed = YES;
        postOff = trimmed(ops[2]);
        }
    NSMutableArray<NSString*>* parts = [splitOperands(inner) mutableCopy];
    if (postOff.length)
        [parts addObject:postOff];
    if (!parts.count)
        {
        [self giveUp:mnem];
        return;
        }
    int rn = regNumber(trimmed(parts[0]));
    if (rn < 0)
        {
        [self giveUp:mnem];
        return;
        }
    // A REGISTER offset, optionally shifted: `[r3, r4, lsl #2]`. Bit 25 selects
    // it, and the shift sits where a data-processing operand's would.
    if (parts.count > 1 && !isImmediate(trimmed(parts[1])))
        {
        int rm = regNumber(trimmed(parts[1]));
        if (rm < 0)
            {
            [self giveUp:mnem];
            return;
            }
        uint32_t kind = 0, amt = 0;
        if (parts.count > 2)
            {
            NSString* sh = trimmed(parts[2]);
            NSRange sp2 = [sh rangeOfString:@" "];
            if (sp2.location == NSNotFound)
                {
                [self giveUp:mnem];
                return;
                }
            kind = shiftKind([sh substringToIndex:sp2.location]);
            amt = immediateValue(trimmed([sh substringFromIndex:sp2.location + 1])) & 31u;
            }
        BOOL ld = [b characterAtIndex:0] == 'l';
        BOOL byteOp = [b isEqualToString:@"ldrb"] || [b isEqualToString:@"strb"];
        if (!byteOp && ![b isEqualToString:@"ldr"] && ![b isEqualToString:@"str"])
            {
            [self giveUp:mnem];
            return; // the half/signed forms encode differently
            }
        uint32_t w = ((uint32_t)_cond << 28) | (1u << 26) | (1u << 25) | (1u << 23);
        if (!postIndexed)
            w |= (1u << 24);
        if (writeback)
            w |= (1u << 21);
        if (byteOp)
            w |= (1u << 22);
        if (ld)
            w |= (1u << 20);
        [self word:w | ((uint32_t)rn << 16) | ((uint32_t)rt << 12) | (amt << 7) | (kind << 5) | (uint32_t)rm];
        return;
        }
    int off = 0;
    if (parts.count > 1)
        {
        NSString* o = trimmed(parts[1]);
        if (!isImmediate(o))
            {
            [self giveUp:mnem];
            return;
            }
        off = (int)immediateValue(o);
        }
    BOOL load = [b characterAtIndex:0] == 'l';
    if (writeback || postIndexed)
        {
        // The immediate-offset indexed forms share one encoding with the plain
        // one: P says pre/post and W says write the base back.
        uint32_t up = off >= 0 ? 1u : 0u;
        uint32_t mag = off >= 0 ? (uint32_t)off : (uint32_t)(-off);
        BOOL byteOp = [b isEqualToString:@"ldrb"] || [b isEqualToString:@"strb"];
        if (!byteOp && ![b isEqualToString:@"ldr"] && ![b isEqualToString:@"str"])
            {
            [self giveUp:mnem];
            return;
            }
        uint32_t w = ((uint32_t)_cond << 28) | (1u << 26) | (up << 23);
        if (!postIndexed)
            w |= (1u << 24) | (1u << 21);
        if (byteOp)
            w |= (1u << 22);
        if (load)
            w |= (1u << 20);
        [self word:w | ((uint32_t)rn << 16) | ((uint32_t)rt << 12) | (mag & 0xFFFu)];
        return;
        }
    if ([b isEqualToString:@"ldrb"] || [b isEqualToString:@"strb"])
        {
        [self loadStore:_cond load:load byte:YES rt:(uint32_t)rt rn:(uint32_t)rn off:off];
        return;
        }
    if ([b isEqualToString:@"ldrh"] || [b isEqualToString:@"strh"])
        {
        [self loadStoreHalf:_cond
                       load:load
                         rt:(uint32_t)rt
                         rn:(uint32_t)rn
                        off:off
                     signed:NO
                   halfword:YES];
        return;
        }
    if ([b isEqualToString:@"ldrsh"])
        {
        [self loadStoreHalf:_cond
                       load:YES
                         rt:(uint32_t)rt
                         rn:(uint32_t)rn
                        off:off
                     signed:YES
                   halfword:YES];
        return;
        }
    if ([b isEqualToString:@"ldrsb"])
        {
        [self loadStoreHalf:_cond
                       load:YES
                         rt:(uint32_t)rt
                         rn:(uint32_t)rn
                        off:off
                     signed:YES
                   halfword:NO];
        return;
        }
    [self loadStore:_cond load:load byte:NO rt:(uint32_t)rt rn:(uint32_t)rn off:off];
    }

// A bare shift is a `mov` with the shift applied to the source.
- (void)encodeShift:(NSString*)b ops:(NSArray<NSString*>*)ops mnem:(NSString*)mnem
    {
    if (ops.count < 3)
        {
        [self giveUp:mnem];
        return;
        }
    int rd = regNumber(ops[0]), rm = regNumber(ops[1]);
    NSString* amt = ops[2];
    if (rd < 0 || rm < 0)
        {
        [self giveUp:mnem];
        return;
        }
    uint32_t kind = shiftKind(b);
    if (isImmediate(amt))
        {
        [self dataProcessing:_cond
                      opcode:13
                    setFlags:_setFlags
                          rd:(uint32_t)rd
                          rn:0
                       imm12:-1
                          rm:(uint32_t)rm
                        kind:kind
                      amount:immediateValue(amt) & 31u];
        return;
        }
    int rs = regNumber(amt);
    if (rs < 0)
        {
        [self giveUp:mnem];
        return;
        }
    // Register-controlled shift: bit 4 set, Rs in bits 11-8.
    [self word:((uint32_t)_cond << 28) | (13u << 21) | ((uint32_t)rd << 12) | ((uint32_t)rs << 8) | (kind << 5) | (1u << 4) | (uint32_t)rm];
    }

// `mov rD, <op2>`, `cmp rN, <op2>`, `add rD, rN, <op2>` — the three arities the
// data-processing forms come in, told apart by which fields the opcode uses.
- (void)encodeDataProcessing:(int)dp ops:(NSArray<NSString*>*)ops mnem:(NSString*)mnem
    {
    BOOL noDest = (dp == 8 || dp == 9 || dp == 10 || dp == 11);
    BOOL noFirst = (dp == 13 || dp == 15);
    if (ops.count < 2)
        {
        [self giveUp:mnem];
        return;
        }
    uint32_t rd = 0, rn = 0;
    NSUInteger opIdx = 1;
    if (noDest)
        {
        int n = regNumber(ops[0]);
        if (n < 0)
            {
            [self giveUp:mnem];
            return;
            }
        rn = (uint32_t)n;
        }
    else if (noFirst)
        {
        int d = regNumber(ops[0]);
        if (d < 0)
            {
            [self giveUp:mnem];
            return;
            }
        rd = (uint32_t)d;
        }
    else
        {
        if (ops.count < 3)
            {
            [self giveUp:mnem];
            return;
            }
        int d = regNumber(ops[0]), n = regNumber(ops[1]);
        if (d < 0 || n < 0)
            {
            [self giveUp:mnem];
            return;
            }
        rd = (uint32_t)d;
        rn = (uint32_t)n;
        opIdx = 2;
        }
    NSString* op2 = ops[opIdx];
    BOOL flags = _setFlags || noDest;
    if (isImmediate(op2))
        {
        int enc = encodeImm12(immediateValue(op2));
        if (enc < 0)
            {
            [self giveUp:@"immediate not encodable"];
            return;
            }
        [self dataProcessing:_cond
                      opcode:dp
                    setFlags:flags
                          rd:rd
                          rn:rn
                       imm12:enc
                          rm:0
                        kind:0
                      amount:0];
        return;
        }
    // A shifted register: `r1, lsl #3`, which arrives as its own operand.
    uint32_t kind = 0, amt = 0;
    int rm = regNumber(op2);
    if (rm < 0)
        {
        [self giveUp:mnem];
        return;
        }
    if (ops.count > opIdx + 1)
        {
        NSString* sh = ops[opIdx + 1];
        NSRange sp2 = [sh rangeOfString:@" "];
        if (sp2.location == NSNotFound)
            {
            [self giveUp:mnem];
            return;
            }
        kind = shiftKind([sh substringToIndex:sp2.location]);
        NSString* by = trimmed([sh substringFromIndex:sp2.location + 1]);
        if (!isImmediate(by))
            {
            // A REGISTER-specified shift (`orr r1, r1, r0, lsr r3`): Rs sits in
            // bits 11-8 and bit 4 says so. Reading it as an immediate silently
            // shifted by the register NUMBER — `lsr r3` became `lsr #3`, which
            // assembles, runs, and is wrong.
            int rs = regNumber(by);
            if (rs < 0)
                {
                [self giveUp:mnem];
                return;
                }
            [self word:((uint32_t)_cond << 28) | ((uint32_t)dp << 21) | (flags ? (1u << 20) : 0u) | (rn << 16) | (rd << 12) | ((uint32_t)rs << 8) | (kind << 5) | (1u << 4) | (uint32_t)rm];
            return;
            }
        amt = immediateValue(by) & 31u;
        }
    [self dataProcessing:_cond
                  opcode:dp
                setFlags:flags
                      rd:rd
                      rn:rn
                   imm12:-1
                      rm:(uint32_t)rm
                    kind:kind
                  amount:amt];
    }

// ── VFP ───────────────────────────────────────────────────────────────────
// The floating-point subset the back end emits. A single-precision register
// splits into (D, M): the low bit goes where a core register number would and
// the top four bits into the field — and the two swap places between the single
// and double forms, which is the whole trick to getting these encodings right.
//
// `s5` -> 5 with *single YES; `d3` -> 3 with it NO.
static int vfpRegNumber(NSString* t, BOOL* single)
    {
    if (t.length < 2)
        return -1;
    unichar k = [t characterAtIndex:0];
    if (k != 's' && k != 'd')
        return -1;
    uint32_t v = 0;
    for (NSUInteger i = 1; i < t.length; i++)
        {
        unichar c = [t characterAtIndex:i];
        if (c < '0' || c > '9')
            return -1;
        v = v * 10 + (uint32_t)(c - '0');
        }
    if (single)
        *single = (k == 's');
    return (int)v;
    }

// The three-bit opcode a VFP data-processing instruction carries. It is NOT a
// contiguous field — bits 23, 21 and 20 select the operation and bit 22 is the
// destination's high bit — so it is given as the word to OR in rather than as a
// number to shift. Bit 6 is the last opcode bit (add vs subtract).
static uint32_t vfpArithBits(NSString* b)
    {
    if ([b isEqualToString:@"vmul"])
        return 1u << 21;
    if ([b isEqualToString:@"vadd"])
        return (1u << 21) | (1u << 20);
    if ([b isEqualToString:@"vsub"])
        return (1u << 21) | (1u << 20) | (1u << 6);
    if ([b isEqualToString:@"vdiv"])
        return 1u << 23;
    if ([b isEqualToString:@"vmla"])
        return 0;
    return 0xFFFFFFFFu;
    }

// The register fields, which move depending on precision: a single's low bit is
// the D/M flag and its top four bits the field; a double's are the other way
// round. Bits 11-8 are the coprocessor field — 0b1010 single, 0b1011 double —
// and leaving it out is the difference between `vadd.f32` and nonsense.
static uint32_t vfpFields(int vd, int vm, int vn, BOOL dbl)
    {
    uint32_t d = dbl ? (((uint32_t)vd >> 4) & 1u) : ((uint32_t)vd & 1u);
    uint32_t vdF = dbl ? ((uint32_t)vd & 0xFu) : ((uint32_t)vd >> 1);
    uint32_t m = dbl ? (((uint32_t)vm >> 4) & 1u) : ((uint32_t)vm & 1u);
    uint32_t vmF = dbl ? ((uint32_t)vm & 0xFu) : ((uint32_t)vm >> 1);
    uint32_t n = dbl ? (((uint32_t)vn >> 4) & 1u) : ((uint32_t)vn & 1u);
    uint32_t vnF = dbl ? ((uint32_t)vn & 0xFu) : ((uint32_t)vn >> 1);
    return (d << 22) | (vnF << 16) | (vdF << 12) | (n << 7) | (m << 5) | vmF | (0xAu << 8) | (dbl ? (1u << 8) : 0u);
    }

- (BOOL)encodeVfp:(NSString*)mnem ops:(NSArray<NSString*>*)ops
    {
    NSArray<NSString*>* parts = [mnem componentsSeparatedByString:@"."];
    NSString* b = parts[0];
    BOOL dbl = parts.count > 1 && [parts[1] isEqualToString:@"f64"];
    if ([b isEqualToString:@"vldr"] || [b isEqualToString:@"vstr"])
        return [self vfpLoadStore:[b isEqualToString:@"vldr"] ops:ops];
    if ([b isEqualToString:@"vld1"] || [b isEqualToString:@"vst1"])
        return [self neonListLoadStore:[b isEqualToString:@"vld1"] parts:parts ops:ops];
    if ([b isEqualToString:@"vdup"])
        return [self neonDup:parts ops:ops];
    if ([b isEqualToString:@"vpaddl"])
        return [self neonPaddl:parts ops:ops];
    // `vmov.32 rD, dN[i]` — a lane out of a NEON register. Told from the VFP
    // `vmov` by its type suffix, which the scalar form never carries.
    if ([b isEqualToString:@"vmov"] && parts.count > 1)
        return [self neonMoveLane:parts ops:ops];
    if ([self neonThreeSame:b parts:parts ops:ops])
        return YES;
    if ([b isEqualToString:@"vmov"])
        return [self vfpMove:ops];
    if ([b isEqualToString:@"vcvt"])
        return [self vfpConvert:parts ops:ops];
    if ([b isEqualToString:@"vcmp"])
        return [self vfpCompare:dbl ops:ops];
    if ([b isEqualToString:@"vmrs"] || [b isEqualToString:@"vmsr"])
        return [self vfpStatus:[b isEqualToString:@"vmrs"] ops:ops];
    if ([b isEqualToString:@"vneg"] || [b isEqualToString:@"vsqrt"])
        return [self vfpArithmetic:0 dbl:dbl base:b ops:ops];
    uint32_t bits = vfpArithBits(b);
    if (bits == 0xFFFFFFFFu)
        return NO;
    return [self vfpArithmetic:bits dbl:dbl base:b ops:ops];
    }

// vldr/vstr: `<reg>, [rN, #±off]`, the offset in WORDS (single) or double-words
// — it is always a multiple of four, encoded /4.
- (BOOL)vfpLoadStore:(BOOL)load ops:(NSArray<NSString*>*)ops
    {
    if (ops.count < 2)
        return NO;
    BOOL single = NO;
    int vd = vfpRegNumber(ops[0], &single);
    if (vd < 0)
        return NO;
    NSString* addr = ops[1];
    if (addr.length < 2 || [addr characterAtIndex:0] != '[')
        return NO;
    NSArray<NSString*>* parts =
        splitOperands([addr substringWithRange:NSMakeRange(1, addr.length - 2)]);
    if (!parts.count)
        return NO;
    int rn = regNumber(trimmed(parts[0]));
    if (rn < 0)
        return NO;
    int off = 0;
    if (parts.count > 1)
        {
        NSString* o = trimmed(parts[1]);
        if (!isImmediate(o))
            return NO;
        off = (int)immediateValue(o);
        }
    uint32_t up = off >= 0 ? 1u : 0u;
    uint32_t mag = (off >= 0 ? (uint32_t)off : (uint32_t)(-off)) >> 2;
    uint32_t d = single ? ((uint32_t)vd & 1u) : (((uint32_t)vd >> 4) & 1u);
    uint32_t vdField = single ? ((uint32_t)vd >> 1) : ((uint32_t)vd & 0xFu);
    [self word:(0xEu << 28) | (0xDu << 24) | (up << 23) | (d << 22) | ((load ? 1u : 0u) << 20) | ((uint32_t)rn << 16) | (vdField << 12) | ((single ? 0xAu : 0xBu) << 8) | (mag & 0xFFu)];
    return YES;
    }

// ── NEON integer ──────────────────────────────────────────────────────────
// The auto-vectoriser's output. A Q register is a PAIR of D registers, so `q10`
// is D20 and every field below is a D-register number split the same way the
// VFP double forms split theirs: bit 4 goes to the D/N/M flag, the low four to
// the field. Returns -1 for anything that is not a NEON register.
static int neonRegNumber(NSString* t, BOOL* quad)
    {
    if (t.length < 2)
        return -1;
    unichar k = [t characterAtIndex:0];
    if (k != 'q' && k != 'd')
        return -1;
    uint32_t v = 0;
    for (NSUInteger i = 1; i < t.length; i++)
        {
        unichar c = [t characterAtIndex:i];
        if (c < '0' || c > '9')
            return -1;
        v = v * 10 + (uint32_t)(c - '0');
        }
    if (quad)
        *quad = (k == 'q');
    return (int)(k == 'q' ? v * 2 : v);
    }

// The element size a `.i32` / `.s16` / `.u8` suffix names.
static int neonSizeBits(NSString* ty)
    {
    if (ty.length < 2)
        return -1;
    NSString* bits = [ty substringFromIndex:1]; // drop the i/s/u/f
    if ([bits isEqualToString:@"8"])
        return 0;
    if ([bits isEqualToString:@"16"])
        return 1;
    if ([bits isEqualToString:@"32"])
        return 2;
    if ([bits isEqualToString:@"64"])
        return 3;
    return -1;
    }

// `<op>.<ty> <Vd>, <Vn>, <Vm>` — the "three registers of the same length"
// family, which is one encoding with an opcode, a U bit and bit 4 selecting the
// operation:
//
//   1111 001 U 0 D size Vn Vd opc N Q M b4 Vm
//
// Only the forms the back end emits are listed. An encoding no test covers is a
// liability rather than a feature, so every row here appears in
// tests/asm-arm32/neon.s and is checked against `as`.
- (BOOL)neonThreeSame:(NSString*)b parts:(NSArray<NSString*>*)parts
                  ops:(NSArray<NSString*>*)ops
    {
    uint32_t u, opc, b4;
    BOOL sizeFromSuffix = YES;
    BOOL dOnly = NO; // no quad form emitted
    if ([b isEqualToString:@"vadd"])
        {
        u = 0;
        opc = 0x8;
        b4 = 0;
        }
    else if ([b isEqualToString:@"vsub"])
        {
        u = 1;
        opc = 0x8;
        b4 = 0;
        }
    else if ([b isEqualToString:@"vmul"])
        {
        u = 0;
        opc = 0x9;
        b4 = 1;
        }
    else if ([b isEqualToString:@"vceq"])
        {
        u = 1;
        opc = 0x8;
        b4 = 1;
        }
    else if ([b isEqualToString:@"vmax"])
        {
        u = 0;
        opc = 0x6;
        b4 = 0;
        }
    else if ([b isEqualToString:@"vmin"])
        {
        u = 0;
        opc = 0x6;
        b4 = 1;
        }
    else if ([b isEqualToString:@"vpadd"])
        {
        u = 0;
        opc = 0xB;
        b4 = 1;
        dOnly = YES;
        }
    else if ([b isEqualToString:@"vpmax"])
        {
        u = 0;
        opc = 0xA;
        b4 = 0;
        dOnly = YES;
        }
    else if ([b isEqualToString:@"vpmin"])
        {
        u = 0;
        opc = 0xA;
        b4 = 1;
        dOnly = YES;
        }
    // The bitwise ops carry no element size: the "size" field selects WHICH
    // bitwise operation — 00 VAND, 01 VBIC, 10 VORR, 11 VORN. (It is 10 for
    // VORR, not 01; the test caught that.)
    else if ([b isEqualToString:@"vand"])
        {
        u = 0;
        opc = 0x1;
        b4 = 1;
        sizeFromSuffix = NO;
        }
    else if ([b isEqualToString:@"vorr"])
        {
        u = 0;
        opc = 0x1;
        b4 = 1;
        sizeFromSuffix = NO;
        }
    else
        return NO;

    // A `.f32` suffix means the FLOATING-point form, which is a different
    // encoding — leave it to the VFP path rather than assembling nonsense.
    if (parts.count > 1 && [parts[1] hasPrefix:@"f"])
        return NO;
    uint32_t size;
    if (sizeFromSuffix)
        {
        if (parts.count < 2)
            return NO;
        int s = neonSizeBits(parts[1]);
        if (s < 0)
            return NO;
        size = (uint32_t)s;
        }
    else
        {
        size = [b isEqualToString:@"vorr"] ? 2u : 0u;
        }
    if (ops.count < 3)
        return NO;
    BOOL qd = NO, qn = NO, qm = NO;
    int vd = neonRegNumber(ops[0], &qd);
    int vn = neonRegNumber(ops[1], &qn);
    int vm = neonRegNumber(ops[2], &qm);
    if (vd < 0 || vn < 0 || vm < 0)
        return NO;
    if (qd != qn || qd != qm)
        return NO; // all three the same shape
    if (dOnly && qd)
        return NO; // pairwise ops are D-only
    [self word:0xF2000000u | (u << 24) | ((((uint32_t)vd >> 4) & 1u) << 22) | (size << 20) | (((uint32_t)vn & 0xFu) << 16) | (((uint32_t)vd & 0xFu) << 12) | (opc << 8) | ((((uint32_t)vn >> 4) & 1u) << 7) | ((qd ? 1u : 0u) << 6) | ((((uint32_t)vm >> 4) & 1u) << 5) | (b4 << 4) | ((uint32_t)vm & 0xFu)];
    return YES;
    }

// `vdup.32 q10, r0` — broadcast a core register across every lane. The element
// size is TWO bits in two different places (B at 22, E at 5), which is why it
// is a table rather than a shift.
- (BOOL)neonDup:(NSArray<NSString*>*)parts ops:(NSArray<NSString*>*)ops
    {
    if (parts.count < 2 || ops.count < 2)
        return NO;
    uint32_t bBit, eBit;
    if ([parts[1] isEqualToString:@"8"])
        {
        bBit = 1;
        eBit = 0;
        }
    else if ([parts[1] isEqualToString:@"16"])
        {
        bBit = 0;
        eBit = 1;
        }
    else if ([parts[1] isEqualToString:@"32"])
        {
        bBit = 0;
        eBit = 0;
        }
    else
        return NO;
    BOOL quad = NO;
    int vd = neonRegNumber(ops[0], &quad);
    int rt = regNumber(ops[1]);
    if (vd < 0 || rt < 0)
        return NO;
    [self word:0xEE800B10u | (bBit << 22) | ((quad ? 1u : 0u) << 21) | (((uint32_t)vd & 0xFu) << 16) | ((uint32_t)rt << 12) | ((((uint32_t)vd >> 4) & 1u) << 7) | (eBit << 5)];
    return YES;
    }

// `vpaddl.u16 q10, q9` — pairwise add long, each pair of lanes summed into one
// of twice the width.
- (BOOL)neonPaddl:(NSArray<NSString*>*)parts ops:(NSArray<NSString*>*)ops
    {
    if (parts.count < 2 || ops.count < 2)
        return NO;
    NSString* ty = parts[1];
    if (![ty hasPrefix:@"u"] && ![ty hasPrefix:@"s"])
        return NO;
    int s = neonSizeBits(ty);
    if (s < 0)
        return NO;
    uint32_t op = [ty hasPrefix:@"u"] ? 1u : 0u;
    BOOL qd = NO, qm = NO;
    int vd = neonRegNumber(ops[0], &qd);
    int vm = neonRegNumber(ops[1], &qm);
    if (vd < 0 || vm < 0 || qd != qm)
        return NO;
    [self word:0xF3B00200u | ((((uint32_t)vd >> 4) & 1u) << 22) | ((uint32_t)s << 18) | (((uint32_t)vd & 0xFu) << 12) | (op << 7) | ((qd ? 1u : 0u) << 6) | ((((uint32_t)vm >> 4) & 1u) << 5) | ((uint32_t)vm & 0xFu)];
    return YES;
    }

// `vmov.32 r0, d20[0]` — one lane out to a core register. Only the .32 form is
// emitted, and only that way round; the other widths index the lane across more
// than one field and nothing here needs them.
- (BOOL)neonMoveLane:(NSArray<NSString*>*)parts ops:(NSArray<NSString*>*)ops
    {
    if (parts.count < 2 || ops.count < 2)
        return NO;
    if (![parts[1] isEqualToString:@"32"])
        return NO;
    int rt = regNumber(ops[0]);
    if (rt < 0)
        return NO;
    NSString* src = ops[1];
    NSRange lb = [src rangeOfString:@"["];
    if (lb.location == NSNotFound || ![src hasSuffix:@"]"])
        return NO;
    BOOL quad = NO;
    int vn = neonRegNumber([src substringToIndex:lb.location], &quad);
    if (vn < 0 || quad)
        return NO;
    uint32_t idx = decimalValue([src substringWithRange:
                                         NSMakeRange(lb.location + 1, src.length - lb.location - 2)]);
    if (idx > 1)
        return NO;
    [self word:0xEE100B10u | (idx << 21) | (((uint32_t)vn & 0xFu) << 16) | ((uint32_t)rt << 12) | ((((uint32_t)vn >> 4) & 1u) << 7)];
    return YES;
    }

// `vld1.8 {d30, d31}, [r0]!` — NEON "multiple single elements". The back end
// emits exactly the two-register form, for block copies; the one- and
// four-register forms are here because the list length is the only thing that
// changes and all three are checked against `as` (tests/asm-arm32/neon.s).
//
//   1111 0100 0 D L 0  Rn  Vd  type  size align  Rm
//
// `type` is the LIST LENGTH, and not in a sane order: 1 reg is 0b0111, 2 is
// 0b1010, 4 is 0b0010. `Rm` is the writeback selector rather than a register —
// 0b1101 (sp) means "advance by the transfer size", 0b1111 (pc) means "do not".
// The three-register form is deliberately absent: nothing emits it, and an
// encoding no test covers is a liability rather than a feature.
- (BOOL)neonListLoadStore:(BOOL)load parts:(NSArray<NSString*>*)parts
                      ops:(NSArray<NSString*>*)ops
    {
    if (ops.count < 2)
        return NO;
    uint32_t size;
    if (parts.count < 2)
        return NO;
    NSString* sz = parts[1];
    if ([sz isEqualToString:@"8"])
        size = 0;
    else if ([sz isEqualToString:@"16"])
        size = 1;
    else if ([sz isEqualToString:@"32"])
        size = 2;
    else if ([sz isEqualToString:@"64"])
        size = 3;
    else
        return NO;

    // The register list. `{d30, d31}` is one operand, so its commas are split
    // here rather than by the operand splitter.
    NSString* list = ops[0];
    if (![list hasPrefix:@"{"] || ![list hasSuffix:@"}"])
        return NO;
    NSArray<NSString*>* items =
        [[list substringWithRange:NSMakeRange(1, list.length - 2)]
            componentsSeparatedByString:@","];
    NSMutableArray<NSNumber*>* regs = [NSMutableArray array];
    for (NSString* raw in items)
        {
        BOOL single = NO;
        int r = vfpRegNumber(trimmed(raw), &single);
        if (r < 0 || single)
            return NO; // D registers only
        [regs addObject:@(r)];
        }
    uint32_t type;
    if (regs.count == 1)
        type = 0x7;
    else if (regs.count == 2)
        type = 0xA;
    else if (regs.count == 4)
        type = 0x2;
    else
        return NO;
    // Consecutive, which the encoding assumes: only the first is named.
    for (NSUInteger i = 1; i < regs.count; i++)
        if (regs[i].intValue != regs[i - 1].intValue + 1)
            return NO;

    NSString* addr = ops[1];
    BOOL writeback = [addr hasSuffix:@"!"];
    if (writeback)
        addr = [addr substringToIndex:addr.length - 1];
    if (![addr hasPrefix:@"["] || ![addr hasSuffix:@"]"])
        return NO;
    int rn = regNumber(trimmed([addr substringWithRange:NSMakeRange(1, addr.length - 2)]));
    if (rn < 0)
        return NO;

    uint32_t vd = (uint32_t)regs[0].intValue;
    [self word:0xF4000000u | ((vd >> 4) & 1u) << 22 | (load ? (1u << 21) : 0u) | ((uint32_t)rn << 16) | ((vd & 0xFu) << 12) | (type << 8) | (size << 6) | (writeback ? 0xDu : 0xFu)];
    return YES;
    }

// vmov between a core register and a single-precision one, either way.
- (BOOL)vfpMove:(NSArray<NSString*>*)ops
    {
    if (ops.count < 2)
        return NO;
    int a = vfpRegNumber(ops[0], NULL);
    int b = vfpRegNumber(ops[1], NULL);
    int ra = regNumber(ops[0]);
    int rb = regNumber(ops[1]);
    // vmov sN, rM  (to the FPU)
    if (a >= 0 && rb >= 0)
        {
        [self word:0xEE000A10u | ((((uint32_t)a >> 1) & 0xFu) << 16) | (((uint32_t)a & 1u) << 7) | ((uint32_t)rb << 12)];
        return YES;
        }
    // vmov rN, sM  (from it)
    if (ra >= 0 && b >= 0)
        {
        [self word:0xEE100A10u | ((((uint32_t)b >> 1) & 0xFu) << 16) | (((uint32_t)b & 1u) << 7) | ((uint32_t)ra << 12)];
        return YES;
        }
    return NO;
    }

- (BOOL)vfpCompare:(BOOL)dbl ops:(NSArray<NSString*>*)ops
    {
    if (ops.count < 2)
        return NO;
    int vd = vfpRegNumber(ops[0], NULL);
    int vm = vfpRegNumber(ops[1], NULL);
    if (vd < 0 || vm < 0)
        return NO;
    [self word:0xEEB40040u | vfpFields(vd, vm, 0, dbl)];
    return YES;
    }

// `vmrs APSR_nzcv, fpscr` and `vmsr fpscr, rN` — the two spellings that reach
// here, and the only two the back end emits.
- (BOOL)vfpStatus:(BOOL)toCore ops:(NSArray<NSString*>*)ops
    {
    if (ops.count < 2)
        return NO;
    if (toCore)
        {
        NSString* dst = ops[0];
        int r = [dst isEqualToString:@"APSR_nzcv"] ? 15 : regNumber(dst);
        if (r < 0)
            return NO;
        [self word:0xEEF10A10u | ((uint32_t)r << 12)];
        return YES;
        }
    int rt = regNumber(ops[1]);
    if (rt < 0)
        return NO;
    [self word:0xEEE10A10u | ((uint32_t)rt << 12)];
    return YES;
    }

- (BOOL)vfpArithmetic:(uint32_t)opBits dbl:(BOOL)dbl base:(NSString*)b
                  ops:(NSArray<NSString*>*)ops
    {
    BOOL unary = [b isEqualToString:@"vneg"] || [b isEqualToString:@"vsqrt"];
    NSUInteger need = unary ? 2 : 3;
    if (ops.count < need)
        return NO;
    int vd = vfpRegNumber(ops[0], NULL);
    if (vd < 0)
        return NO;
    if (unary)
        {
        int vm = vfpRegNumber(ops[1], NULL);
        if (vm < 0)
            return NO;
        uint32_t base = [b isEqualToString:@"vneg"] ? 0xEEB10040u : 0xEEB100C0u;
        [self word:base | vfpFields(vd, vm, 0, dbl)];
        return YES;
        }
    int vn = vfpRegNumber(ops[1], NULL);
    int vm = vfpRegNumber(ops[2], NULL);
    if (vn < 0 || vm < 0)
        return NO;
    [self word:0xEE000000u | opBits | vfpFields(vd, vm, vn, dbl)];
    return YES;
    }

// vcvt between the two float widths, and between float and integer.
- (BOOL)vfpConvert:(NSArray<NSString*>*)parts ops:(NSArray<NSString*>*)ops
    {
    if (parts.count < 3 || ops.count < 2)
        return NO;
    NSString *to = parts[1], *from = parts[2];
    int vd = vfpRegNumber(ops[0], NULL);
    int vm = vfpRegNumber(ops[1], NULL);
    if (vd < 0 || vm < 0)
        return NO;
    BOOL toF64 = [to isEqualToString:@"f64"], fromF64 = [from isEqualToString:@"f64"];
    BOOL toF32 = [to isEqualToString:@"f32"], fromF32 = [from isEqualToString:@"f32"];
    if ((toF64 && fromF32) || (toF32 && fromF64))
        {
        // f32<->f64: the SOURCE precision picks the encoding's sz bit and the
        // destination is the other width, so the fields are mixed.
        uint32_t d = toF64 ? (((uint32_t)vd >> 4) & 1u) : ((uint32_t)vd & 1u);
        uint32_t vdF = toF64 ? ((uint32_t)vd & 0xFu) : ((uint32_t)vd >> 1);
        uint32_t m = fromF64 ? (((uint32_t)vm >> 4) & 1u) : ((uint32_t)vm & 1u);
        uint32_t vmF = fromF64 ? ((uint32_t)vm & 0xFu) : ((uint32_t)vm >> 1);
        [self word:0xEEB700C0u | (0xAu << 8) | (d << 22) | (vdF << 12) | (m << 5) | vmF | (fromF64 ? (1u << 8) : 0u)];
        return YES;
        }
    BOOL toInt = [to isEqualToString:@"s32"] || [to isEqualToString:@"u32"];
    if (toInt)
        {
        // float -> int, round toward zero: opc2 = 101 (signed) / 100.
        BOOL sgn = [to isEqualToString:@"s32"];
        uint32_t d = (uint32_t)vd & 1u;
        uint32_t vdF = (uint32_t)vd >> 1;
        uint32_t m = fromF64 ? (((uint32_t)vm >> 4) & 1u) : ((uint32_t)vm & 1u);
        uint32_t vmF = fromF64 ? ((uint32_t)vm & 0xFu) : ((uint32_t)vm >> 1);
        [self word:0xEEBC00C0u | (0xAu << 8) | ((sgn ? 1u : 0u) << 16) | (d << 22) | (vdF << 12) | (m << 5) | vmF | (fromF64 ? (1u << 8) : 0u)];
        return YES;
        }
    // int -> float: the SOURCE is the integer, in a single register.
    BOOL sgn = [from isEqualToString:@"s32"];
    uint32_t d = toF64 ? (((uint32_t)vd >> 4) & 1u) : ((uint32_t)vd & 1u);
    uint32_t vdF = toF64 ? ((uint32_t)vd & 0xFu) : ((uint32_t)vd >> 1);
    uint32_t m = (uint32_t)vm & 1u;
    uint32_t vmF = (uint32_t)vm >> 1;
    [self word:0xEEB80040u | (0xAu << 8) | ((sgn ? 1u : 0u) << 7) | (d << 22) | (vdF << 12) | (m << 5) | vmF | (toF64 ? (1u << 8) : 0u)];
    return YES;
    }

@end
