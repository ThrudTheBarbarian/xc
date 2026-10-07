// XTDwarfWriter.m — DWARF 4 debug information for an executable xcc linked
#import "XTDwarfWriter.h"

#ifndef XTC_VERSION
#define XTC_VERSION "?"
#endif

typedef struct
    {
    uint64_t offset;
    uint32_t file, line, column;
    } XTDwarfRow;

static void putU8(NSMutableData* d, uint8_t v)
    {
    [d appendBytes:&v length:1];
    }

static void putU16(NSMutableData* d, uint16_t v)
    {
    uint8_t b[2] = {(uint8_t)v, (uint8_t)(v >> 8)};
    [d appendBytes:b length:2];
    }

static void putU32(NSMutableData* d, uint32_t v)
    {
    uint8_t b[4] = {(uint8_t)v, (uint8_t)(v >> 8), (uint8_t)(v >> 16), (uint8_t)(v >> 24)};
    [d appendBytes:b length:4];
    }

static void putU64(NSMutableData* d, uint64_t v)
    {
    putU32(d, (uint32_t)v);
    putU32(d, (uint32_t)(v >> 32));
    }

static void putULEB(NSMutableData* d, uint64_t v)
    {
    do
        {
        uint8_t b = v & 0x7f;
        v >>= 7;
        if (v != 0)
            b |= 0x80;
        putU8(d, b);
        }
    while (v != 0);
    }

static void putSLEB(NSMutableData* d, int64_t v)
    {
    BOOL more = YES;
    while (more)
        {
        uint8_t b = v & 0x7f;
        v >>= 7;
        if ((v == 0 && !(b & 0x40)) || (v == -1 && (b & 0x40)))
            more = NO;
        else
            b |= 0x80;
        putU8(d, b);
        }
    }

static void putCString(NSMutableData* d, NSString* s)
    {
    const char* c = s.UTF8String;
    [d appendBytes:c length:strlen(c) + 1];
    }

static void patchU32(NSMutableData* d, NSUInteger at, uint32_t v)
    {
    uint8_t b[4] = {(uint8_t)v, (uint8_t)(v >> 8), (uint8_t)(v >> 16), (uint8_t)(v >> 24)};
    [d replaceBytesInRange:NSMakeRange(at, 4) withBytes:b];
    }

// DWARF constants used here.
enum
    {
    DW_TAG_compile_unit = 0x11,
    DW_TAG_subprogram = 0x2e,
    DW_TAG_variable = 0x34,
    DW_TAG_formal_parameter = 0x05,
    DW_TAG_base_type = 0x24,
    DW_TAG_pointer_type = 0x0f,
    DW_AT_byte_size = 0x0b,
    DW_AT_encoding = 0x3e,
    DW_AT_type = 0x49,
    DW_AT_location = 0x02,
    DW_FORM_data1 = 0x0b,
    DW_FORM_ref4 = 0x13,
    DW_OP_breg0 = 0x70,
    DW_AT_name = 0x03,
    DW_AT_stmt_list = 0x10,
    DW_AT_low_pc = 0x11,
    DW_AT_high_pc = 0x12,
    DW_AT_language = 0x13,
    DW_AT_comp_dir = 0x1b,
    DW_AT_producer = 0x25,
    DW_AT_external = 0x3f,
    DW_AT_frame_base = 0x40,
    DW_FORM_addr = 0x01,
    DW_FORM_data2 = 0x05,
    DW_FORM_data8 = 0x07,
    DW_FORM_strp = 0x0e,
    DW_FORM_sec_offset = 0x17,
    DW_FORM_exprloc = 0x18,
    DW_FORM_flag_present = 0x19,
    DW_LANG_C99 = 0x0c,
    DW_OP_reg0 = 0x50,
    DW_LNS_copy = 1,
    DW_LNS_advance_pc = 2,
    DW_LNS_advance_line = 3,
    DW_LNS_set_file = 4,
    DW_LNS_set_column = 5,
    DW_LNE_end_sequence = 1,
    DW_LNE_set_address = 2,
    };

static XTDwarfWriter* gPending = nil;

@implementation XTDwarfWriter
    {
    NSMutableData* _rows; // XTDwarfRow records, in offset order
    NSMutableArray<NSNumber*>* _frameSetups;
    NSMutableArray<NSArray*>* _variables; // @[at, name, reg, offset, type]
    }

- (instancetype)init
    {
    self = [super init];
    if (self)
        {
        _files = [NSMutableDictionary dictionary];
        _rows = [NSMutableData data];
        _frameSetups = [NSMutableArray array];
        _variables = [NSMutableArray array];
        }
    return self;
    }

+ (nullable XTDwarfWriter*)pending
    {
    return gPending;
    }

+ (void)setPending:(nullable XTDwarfWriter*)writer
    {
    gPending = writer;
    }

- (void)setFile:(uint32_t)number path:(NSString*)path
    {
    _files[@(number)] = path;
    }

- (void)addRowAtOffset:(uint64_t)offset file:(uint32_t)file line:(uint32_t)line column:(uint32_t)column
    {
    NSUInteger n = _rows.length / sizeof(XTDwarfRow);
    XTDwarfRow* rows = (XTDwarfRow*)_rows.mutableBytes;
    // Two locations at one address (a statement that emitted no code): the
    // later one is the one that address belongs to.
    if (n > 0 && rows[n - 1].offset == offset)
        {
        rows[n - 1] = (XTDwarfRow){offset, file, line, column};
        return;
        }
    XTDwarfRow r = {offset, file, line, column};
    [_rows appendBytes:&r length:sizeof r];
    }

- (void)addFrameSetupAtOffset:(uint64_t)offset
    {
    [_frameSetups addObject:@(offset)];
    }

- (void)addVariable:(NSString*)name
         atOffset:(uint64_t)at
         register:(uint8_t)reg
           offset:(int64_t)offset
             type:(NSString*)type
        parameter:(BOOL)parameter
    {
    [_variables addObject:@[ @(at), name, @(reg), @(offset), type, @(parameter) ]];
    }

- (BOOL)hasRows
    {
    return _rows.length > 0;
    }

- (NSDictionary<NSString*, NSData*>*)sectionsForTextAddress:(uint64_t)textAddress
                                                   textSize:(uint64_t)textSize
                                                  functions:(NSDictionary<NSString*, NSNumber*>*)functions
                                              minInsnLength:(uint8_t)minInsnLength
                                              frameRegister:(uint8_t)frameRegister
    {
    NSMutableData* str = [NSMutableData data];
    NSMutableDictionary<NSString*, NSNumber*>* strOffsets = [NSMutableDictionary dictionary];
    uint32_t (^strp)(NSString*) = ^uint32_t(NSString* s)
        {
        NSNumber* have = strOffsets[s];
        if (have)
            return have.unsignedIntValue;
        uint32_t at = (uint32_t)str.length;
        putCString(str, s);
        strOffsets[s] = @(at);
        return at;
        };

    // File numbers as `.file` gave them; the line table numbers files from 1.
    uint32_t maxFile = 0;
    for (NSNumber* k in _files)
        maxFile = MAX(maxFile, k.unsignedIntValue);

    // ---- .debug_line ----
    NSMutableData* line = [NSMutableData data];
    putU32(line, 0); // unit_length, patched
    putU16(line, 4);
    NSUInteger headerLengthAt = line.length;
    putU32(line, 0); // header_length, patched
    NSUInteger headerStart = line.length;
    putU8(line, minInsnLength);
    putU8(line, 1);    // maximum_operations_per_instruction
    putU8(line, 1);    // default_is_stmt
    putU8(line, (uint8_t)-5); // line_base
    putU8(line, 14);   // line_range
    putU8(line, 13);   // opcode_base
    static const uint8_t stdLengths[12] = {0, 1, 1, 1, 1, 0, 0, 0, 1, 0, 0, 1};
    [line appendBytes:stdLengths length:12];
    putU8(line, 0); // no include directories: file names are full paths
    for (uint32_t f = 1; f <= maxFile; f++)
        {
        putCString(line, _files[@(f)] ?: @"<unknown>");
        putULEB(line, 0);
        putULEB(line, 0);
        putULEB(line, 0);
        }
    putU8(line, 0);
    patchU32(line, headerLengthAt, (uint32_t)(line.length - headerStart));

    const XTDwarfRow* rows = (const XTDwarfRow*)_rows.bytes;
    NSUInteger n = _rows.length / sizeof(XTDwarfRow);
    putU8(line, 0);
    putULEB(line, 9);
    putU8(line, DW_LNE_set_address);
    putU64(line, textAddress);
    uint64_t addr = 0;
    int64_t curLine = 1;
    uint32_t curFile = 1, curCol = 0;
    for (NSUInteger i = 0; i < n; i++)
        {
        const XTDwarfRow* r = &rows[i];
        if (r->offset > addr)
            {
            putU8(line, DW_LNS_advance_pc);
            putULEB(line, (r->offset - addr) / minInsnLength);
            addr = r->offset;
            }
        if (r->file != curFile)
            {
            putU8(line, DW_LNS_set_file);
            putULEB(line, r->file);
            curFile = r->file;
            }
        if ((int64_t)r->line != curLine)
            {
            putU8(line, DW_LNS_advance_line);
            putSLEB(line, (int64_t)r->line - curLine);
            curLine = r->line;
            }
        if (r->column != curCol)
            {
            putU8(line, DW_LNS_set_column);
            putULEB(line, r->column);
            curCol = r->column;
            }
        putU8(line, DW_LNS_copy);
        }
    if (textSize > addr)
        {
        putU8(line, DW_LNS_advance_pc);
        putULEB(line, (textSize - addr) / minInsnLength);
        }
    putU8(line, 0);
    putULEB(line, 1);
    putU8(line, DW_LNE_end_sequence);
    patchU32(line, 0, (uint32_t)(line.length - 4));

    // ---- .debug_abbrev ----
    NSMutableData* abbrev = [NSMutableData data];
    putULEB(abbrev, 1);
    putULEB(abbrev, DW_TAG_compile_unit);
    putU8(abbrev, 1); // has children
    uint16_t cuAttrs[][2] = {
        {DW_AT_producer, DW_FORM_strp}, {DW_AT_language, DW_FORM_data2}, {DW_AT_name, DW_FORM_strp},
        {DW_AT_comp_dir, DW_FORM_strp}, {DW_AT_low_pc, DW_FORM_addr}, {DW_AT_high_pc, DW_FORM_data8},
        {DW_AT_stmt_list, DW_FORM_sec_offset}};
    for (size_t i = 0; i < sizeof cuAttrs / sizeof cuAttrs[0]; i++)
        {
        putULEB(abbrev, cuAttrs[i][0]);
        putULEB(abbrev, cuAttrs[i][1]);
        }
    putU8(abbrev, 0);
    putU8(abbrev, 0);
    putULEB(abbrev, 2);
    putULEB(abbrev, DW_TAG_subprogram);
    putU8(abbrev, 0);
    uint16_t spAttrs[][2] = {
        {DW_AT_name, DW_FORM_strp}, {DW_AT_low_pc, DW_FORM_addr}, {DW_AT_high_pc, DW_FORM_data8},
        {DW_AT_external, DW_FORM_flag_present}, {DW_AT_frame_base, DW_FORM_exprloc}};
    for (size_t i = 0; i < sizeof spAttrs / sizeof spAttrs[0]; i++)
        {
        putULEB(abbrev, spAttrs[i][0]);
        putULEB(abbrev, spAttrs[i][1]);
        }
    putU8(abbrev, 0);
    putU8(abbrev, 0);
    // 3: a subprogram with variables (the same attributes, and children).
    putULEB(abbrev, 3);
    putULEB(abbrev, DW_TAG_subprogram);
    putU8(abbrev, 1);
    for (size_t i = 0; i < sizeof spAttrs / sizeof spAttrs[0]; i++)
        {
        putULEB(abbrev, spAttrs[i][0]);
        putULEB(abbrev, spAttrs[i][1]);
        }
    putU8(abbrev, 0);
    putU8(abbrev, 0);
    // 4: a variable: name, type, location.
    putULEB(abbrev, 4);
    putULEB(abbrev, DW_TAG_variable);
    putU8(abbrev, 0);
    putULEB(abbrev, DW_AT_name);
    putULEB(abbrev, DW_FORM_strp);
    putULEB(abbrev, DW_AT_type);
    putULEB(abbrev, DW_FORM_ref4);
    putULEB(abbrev, DW_AT_location);
    putULEB(abbrev, DW_FORM_exprloc);
    putU8(abbrev, 0);
    putU8(abbrev, 0);
    // 5: a base type: name, encoding, size.
    putULEB(abbrev, 5);
    putULEB(abbrev, DW_TAG_base_type);
    putU8(abbrev, 0);
    putULEB(abbrev, DW_AT_name);
    putULEB(abbrev, DW_FORM_strp);
    putULEB(abbrev, DW_AT_encoding);
    putULEB(abbrev, DW_FORM_data1);
    putULEB(abbrev, DW_AT_byte_size);
    putULEB(abbrev, DW_FORM_data1);
    putU8(abbrev, 0);
    putU8(abbrev, 0);
    // 6: a pointer to a type; 7: a pointer to nothing in particular (void *).
    putULEB(abbrev, 6);
    putULEB(abbrev, DW_TAG_pointer_type);
    putU8(abbrev, 0);
    putULEB(abbrev, DW_AT_type);
    putULEB(abbrev, DW_FORM_ref4);
    putULEB(abbrev, DW_AT_byte_size);
    putULEB(abbrev, DW_FORM_data1);
    putU8(abbrev, 0);
    putU8(abbrev, 0);
    putULEB(abbrev, 7);
    putULEB(abbrev, DW_TAG_pointer_type);
    putU8(abbrev, 0);
    putULEB(abbrev, DW_AT_byte_size);
    putULEB(abbrev, DW_FORM_data1);
    putU8(abbrev, 0);
    putU8(abbrev, 0);
    // 8: a parameter, with the variable's attributes.
    putULEB(abbrev, 8);
    putULEB(abbrev, DW_TAG_formal_parameter);
    putU8(abbrev, 0);
    putULEB(abbrev, DW_AT_name);
    putULEB(abbrev, DW_FORM_strp);
    putULEB(abbrev, DW_AT_type);
    putULEB(abbrev, DW_FORM_ref4);
    putULEB(abbrev, DW_AT_location);
    putULEB(abbrev, DW_FORM_exprloc);
    putU8(abbrev, 0);
    putU8(abbrev, 0);
    putU8(abbrev, 0);

    // ---- .debug_info ----
    NSString* mainFile = _files[@1] ?: @"<unknown>";
    NSMutableData* info = [NSMutableData data];
    putU32(info, 0); // unit_length, patched
    putU16(info, 4);
    putU32(info, 0); // abbrev offset
    putU8(info, 8);  // address size
    putULEB(info, 1);
    putU32(info, strp(@"xcc " XTC_VERSION));
    putU16(info, DW_LANG_C99);
    putU32(info, strp(mainFile.lastPathComponent));
    putU32(info, strp(mainFile.stringByDeletingLastPathComponent));
    putU64(info, textAddress);
    putU64(info, textSize);
    putU32(info, 0); // stmt_list: the one line program, at 0

    // The variables' types, each once, as the IR spells them: scalars become
    // base types and Ptr(T, ...) a pointer to T's entry (Ptr(Void) a bare
    // pointer). A type with no DWARF form here (an aggregate) has no entry and
    // its variables are left out. Offsets are from the start of the unit.
    NSMutableDictionary<NSString*, NSNumber*>* typeDie = [NSMutableDictionary dictionary];
    __block uint32_t (^typeRef)(NSString*);
    __block __weak uint32_t (^weakTypeRef)(NSString*);
    weakTypeRef = typeRef = ^uint32_t(NSString* t) {
      NSNumber* have = typeDie[t];
      if (have)
          return have.unsignedIntValue;
      static NSDictionary<NSString*, NSArray*>* base = nil;
      if (!base)
          base = @{
              @"I8" : @[ @"i8", @0x06, @1 ], @"U8" : @[ @"u8", @0x08, @1 ],
              @"I16" : @[ @"i16", @0x05, @2 ], @"U16" : @[ @"u16", @0x07, @2 ],
              @"I32" : @[ @"i32", @0x05, @4 ], @"U32" : @[ @"u32", @0x07, @4 ],
              @"I64" : @[ @"i64", @0x05, @8 ], @"U64" : @[ @"u64", @0x07, @8 ],
              @"F32" : @[ @"float", @0x04, @4 ], @"F64" : @[ @"double", @0x04, @8 ],
              @"Bool" : @[ @"bool", @0x02, @1 ], @"I1" : @[ @"bool", @0x02, @1 ],
          };
      uint32_t at = 0;
      NSArray* b = base[t];
      if (b)
          {
          at = (uint32_t)info.length;
          putULEB(info, 5);
          putU32(info, strp(b[0]));
          putU8(info, (uint8_t)[b[1] unsignedIntValue]);
          putU8(info, (uint8_t)[b[2] unsignedIntValue]);
          }
      else if ([t hasPrefix:@"Ptr("] && [t hasSuffix:@")"])
          {
          // The pointee is everything up to the top-level comma.
          NSString* inner = [t substringWithRange:NSMakeRange(4, t.length - 5)];
          int depth = 0;
          NSUInteger cut = inner.length;
          for (NSUInteger i = 0; i < inner.length; i++)
              {
              unichar c = [inner characterAtIndex:i];
              if (c == '(')
                  depth++;
              else if (c == ')')
                  depth--;
              else if (c == ',' && depth == 0)
                  {
                  cut = i;
                  break;
                  }
              }
          NSString* pointee = [inner substringToIndex:cut];
          uint32_t to = [pointee isEqualToString:@"Void"] ? 0 : weakTypeRef(pointee);
          at = (uint32_t)info.length;
          if (to)
              {
              putULEB(info, 6);
              putU32(info, to);
              }
          else
              putULEB(info, 7);
          putU8(info, 8);
          }
      typeDie[t] = @(at);
      return at;
    };
    for (NSArray* v in _variables)
        typeRef(v[4]);

    NSArray<NSString*>* names = [functions keysSortedByValueUsingSelector:@selector(compare:)];
    for (NSUInteger i = 0; i < names.count; i++)
        {
        uint64_t start = functions[names[i]].unsignedLongLongValue;
        uint64_t end = (i + 1 < names.count) ? functions[names[i + 1]].unsignedLongLongValue : textSize;
        if (end <= start)
            continue;
        NSMutableArray<NSArray*>* vars = [NSMutableArray array];
        for (NSArray* v in _variables)
            {
            uint64_t at = [v[0] unsignedLongLongValue];
            if (at >= start && at < end && typeDie[v[4]].unsignedIntValue != 0)
                [vars addObject:v];
            }
        putULEB(info, vars.count ? 3 : 2);
        putU32(info, strp(names[i]));
        putU64(info, textAddress + start);
        putU64(info, end - start);
        putULEB(info, 1);
        putU8(info, DW_OP_reg0 + frameRegister);
        if (vars.count)
            {
            // Parameters first, in their order, as a debugger lists them.
            [vars sortWithOptions:NSSortStable
                  usingComparator:^NSComparisonResult(NSArray* x, NSArray* y) {
                    return [y[5] compare:x[5]];
                  }];
            for (NSArray* v in vars)
                {
                putULEB(info, [v[5] boolValue] ? 8 : 4);
                putU32(info, strp(v[1]));
                putU32(info, typeDie[v[4]].unsignedIntValue);
                NSMutableData* loc = [NSMutableData data];
                putU8(loc, DW_OP_breg0 + (uint8_t)[v[2] unsignedIntValue]);
                putSLEB(loc, [v[3] longLongValue]);
                putULEB(info, loc.length);
                [info appendData:loc];
                }
            putU8(info, 0); // end of the subprogram's children
            }
        }
    putU8(info, 0); // end of the compile unit's children
    patchU32(info, 0, (uint32_t)(info.length - 4));

    // ---- .debug_frame ----
    // One CIE: on entry the call frame is the stack pointer and the return
    // address is in the link register. Then one FDE per function, which moves
    // the frame to fp + 16 once the frame record is set up (where fp and lr
    // are saved at -16 and -8).
    NSMutableData* frame = [NSMutableData data];
    uint8_t spReg = (minInsnLength == 4) ? 31 : 7; // arm64 sp / x86-64 rsp
    uint8_t raReg = (minInsnLength == 4) ? 30 : 16; // arm64 lr / x86-64 return address column
    putU32(frame, 0);          // length, patched
    putU32(frame, 0xffffffff); // CIE id
    putU8(frame, 1);           // version
    putU8(frame, 0);           // augmentation ""
    putULEB(frame, minInsnLength); // code alignment
    putSLEB(frame, -8);            // data alignment
    putU8(frame, raReg);
    putU8(frame, 0x0c); // DW_CFA_def_cfa
    putULEB(frame, spReg);
    putULEB(frame, minInsnLength == 4 ? 0 : 8);
    if (minInsnLength != 4)
        {
        putU8(frame, 0x80 | raReg); // DW_CFA_offset: return address at cfa-8
        putULEB(frame, 1);
        }
    while ((frame.length % 8) != 0)
        putU8(frame, 0); // DW_CFA_nop
    patchU32(frame, 0, (uint32_t)(frame.length - 4));
    NSArray<NSNumber*>* setups = [_frameSetups sortedArrayUsingSelector:@selector(compare:)];
    for (NSUInteger i = 0; i < names.count; i++)
        {
        uint64_t start = functions[names[i]].unsignedLongLongValue;
        uint64_t end = (i + 1 < names.count) ? functions[names[i + 1]].unsignedLongLongValue : textSize;
        if (end <= start)
            continue;
        NSUInteger fdeAt = frame.length;
        putU32(frame, 0); // length, patched
        putU32(frame, 0); // CIE at offset 0
        putU64(frame, textAddress + start);
        putU64(frame, end - start);
        for (NSNumber* o in setups)
            {
            uint64_t at = o.unsignedLongLongValue;
            if (at < start || at >= end)
                continue;
            uint64_t delta = (at - start) / minInsnLength;
            putU8(frame, 0x02); // DW_CFA_advance_loc1 (a prologue is short)
            putU8(frame, (uint8_t)MIN(delta, 255));
            putU8(frame, 0x0c); // DW_CFA_def_cfa fp, 16
            putULEB(frame, minInsnLength == 4 ? 29 : 6);
            putULEB(frame, 16);
            putU8(frame, 0x80 | (minInsnLength == 4 ? 29 : 6)); // fp at cfa-16
            putULEB(frame, 2);
            putU8(frame, 0x80 | raReg); // return address at cfa-8
            putULEB(frame, 1);
            break;
            }
        while (((frame.length - fdeAt) % 8) != 0)
            putU8(frame, 0);
        patchU32(frame, fdeAt, (uint32_t)(frame.length - fdeAt - 4));
        }

    return @{@"debug_line" : line, @"debug_info" : info, @"debug_abbrev" : abbrev, @"debug_str" : str,
             @"debug_frame" : frame};
    }

@end
