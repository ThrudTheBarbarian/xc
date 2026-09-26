//xtc-na: xt6502 — Coder is not available on xt6502
// coder_gzip.xc — Coder's gzip against the reference implementation.
//
// The streams below were written by the system `gzip` and by Python's gzip
// module, so this checks the inflater against real encoders on every target:
// dynamic Huffman blocks (gzip -1, -9), a fixed block (a short input), stored
// blocks (level 0), and a header carrying a file name. Then the other
// direction: our own output at every level must come back byte for byte, and a
// damaged stream must be refused with a reason rather than decoded.
//
//   T1  CRC-32 of "123456789" is the standard check value, CBF43926
//   T2  the five reference streams inflate to the expected bytes
//   T3  our gzip at levels 0-9 round-trips a text and a run-heavy buffer
//   T4  a flipped payload bit, a wrong CRC and a truncated stream all throw
#import "Stdio.xc"
#import "Coder.xc"

// Generated from the two inputs below with `gzip -1 -n`, `gzip -9 -n`,
// Python's gzip at level 0 (stored blocks) and Python's GzipFile with a file
// name in the header.
string bigJson = "[{\"id\": 0, \"name\": \"item 0\", \"tags\": [\"red\"], \"price\": 0.0, \"ok\": true}, {\"id\": 1, \"name\": \"item 1\", \"tags\": [\"red\", \"green\"], \"price\": 1.25, \"ok\": false}, {\"id\": 2, \"name\": \"item 2\", \"tags\": [\"red\", \"green\", \"blue\"], \"price\": 2.5, \"ok\": true}, {\"id\": 3, \"name\": \"item 3\", \"tags\": [\"red\"], \"price\": 3.75, \"ok\": false}, {\"id\": 4, \"name\": \"item 4\", \"tags\": [\"red\", \"green\"], \"price\": 5.0, \"ok\": true}, {\"id\": 5, \"name\": \"item 5\", \"tags\": [\"red\", \"green\", \"blue\"], \"price\": 6.25, \"ok\": false}, {\"id\": 6, \"name\": \"item 6\", \"tags\": [\"red\"], \"price\": 7.5, \"ok\": true}, {\"id\": 7, \"name\": \"item 7\", \"tags\": [\"red\", \"green\"], \"price\": 8.75, \"ok\": false}, {\"id\": 8, \"name\": \"item 8\", \"tags\": [\"red\", \"green\", \"blue\"], \"price\": 10.0, \"ok\": true}, {\"id\": 9, \"name\": \"item 9\", \"tags\": [\"red\"], \"price\": 11.25, \"ok\": false}, {\"id\": 10, \"name\": \"item 10\", \"tags\": [\"red\", \"green\"], \"price\": 12.5, \"ok\": true}, {\"id\": 11, \"name\": \"item 11\", \"tags\": [\"red\", \"green\", \"blue\"], \"price\": 13.75, \"ok\": false}, {\"id\": 12, \"name\": \"item 12\", \"tags\": [\"red\"], \"price\": 15.0, \"ok\": true}, {\"id\": 13, \"name\": \"item 13\", \"tags\": [\"red\", \"green\"], \"price\": 16.25, \"ok\": false}, {\"id\": 14, \"name\": \"item 14\", \"tags\": [\"red\", \"green\", \"blue\"], \"price\": 17.5, \"ok\": true}, {\"id\": 15, \"name\": \"item 15\", \"tags\": [\"red\"], \"price\": 18.75, \"ok\": false}, {\"id\": 16, \"name\": \"item 16\", \"tags\": [\"red\", \"green\"], \"price\": 20.0, \"ok\": true}, {\"id\": 17, \"name\": \"item 17\", \"tags\": [\"red\", \"green\", \"blue\"], \"price\": 21.25, \"ok\": false}, {\"id\": 18, \"name\": \"item 18\", \"tags\": [\"red\"], \"price\": 22.5, \"ok\": true}, {\"id\": 19, \"name\": \"item 19\", \"tags\": [\"red\", \"green\"], \"price\": 23.75, \"ok\": false}, {\"id\": 20, \"name\": \"item 20\", \"tags\": [\"red\", \"green\", \"blue\"], \"price\": 25.0, \"ok\": true}, {\"id\": 21, \"name\": \"item 21\", \"tags\": [\"red\"], \"price\": 26.25, \"ok\": false}, {\"id\": 22, \"name\": \"item 22\", \"tags\": [\"red\", \"green\"], \"price\": 27.5, \"ok\": true}, {\"id\": 23, \"name\": \"item 23\", \"tags\": [\"red\", \"green\", \"blue\"], \"price\": 28.75, \"ok\": false}]";
u32 bigLen = 2004;
string smallJson = "{\"a\":[1,2,3],\"b\":\"caf\u00e9\"}";
u32 smallLen = 25;
u8 gzBig1[350] = {
    $1F, $8B, $08, $00, $00, $00, $00, $00, $04, $03, $7D, $93, $CD, $6E, $C2, $30,
    $10, $84, $5F, $25, $F2, $19, $45, $99, $0D, $F9, $A1, $AF, $82, $38, $A4, $E0,
    $A2, $A8, $40, $AB, $10, $4E, $55, $DF, $BD, $8E, $44, $51, $EC, $F1, $EE, $2D,
    $B2, $36, $5F, $3C, $9B, $F9, $F6, $3F, $6E, $3C, $B9, $B7, $A2, $DA, $14, $EE,
    $36, $5C, $7D, $78, $74, $E3, $EC, $AF, $45, $E5, $C2, $C9, $3C, $9C, $EF, $E1,
    $64, $EF, $26, $7F, $72, $87, $70, $F0, $3D, $8D, $C7, $65, $A6, $2A, $97, $17,
    $BE, $3E, $C3, $E3, $3C, $3D, $FC, $EF, $A6, $78, $72, $90, $72, $40, $9C, $30,
    $71, $9E, $BC, $BF, $45, $40, $94, $D2, $FC, $13, $3F, $86, $CB, $7D, $85, $94,
    $14, $29, $3A, $32, $8C, $BE, $5F, $1E, $3E, $42, $4B, $F9, $22, $C7, $77, $AD,
    $53, $70, $4D, $E0, $75, $E6, $BA, $EC, $5E, $A0, $E4, $8A, $DB, $94, $B4, $25,
    $52, $98, $E0, $D4, $8D, $B6, $C6, $E5, $43, $D1, $EF, $68, $74, $60, $18, $A5,
    $CC, $AD, $BE, $CE, $36, $45, $B7, $84, $5E, $A7, $EE, $B4, $ED, $75, $29, $A7,
    $23, $4E, $98, $E0, $CC, $BD, $BE, $C6, $3E, $45, $F6, $3A, $32, $8C, $52, $6A,
    $A8, $B5, $DC, $A5, $E4, $1D, $91, $D7, $A1, $61, $D4, $11, $A4, $0A, $D8, $95,
    $6C, $72, $A8, $4D, $04, $6B, $63, $78, $93, $8D, $6E, $B4, $13, $64, $10, $58,
    $A1, $28, $BE, $DA, $4B, $90, $33, $60, $69, $F2, $E1, $8D, $4A, $82, $FC, $81,
    $21, $50, $36, $BE, $5A, $53, $90, $4A, $60, $97, $A2, $F0, $46, $41, $41, $F2,
    $80, $ED, $C9, $C6, $17, $B5, $9A, $20, $91, $60, $98, $94, $0B, $2F, $56, $5B,
    $C9, $29, $B0, $54, $EB, $F8, $A2, $97, $94, $24, $02, $5B, $94, $0F, $6F, $94,
    $53, $48, $27, $31, $74, $CA, $C6, $57, $DB, $2A, $A4, $95, $B0, $56, $51, $78,
    $A3, $A4, $42, $16, $09, $5B, $94, $8F, $AF, $96, $53, $48, $27, $31, $74, $CA,
    $86, $E7, $B6, $1E, $FE, $00, $63, $6D, $EC, $E9, $D4, $07, $00, $00
};

u8 gzBig9[315] = {
    $1F, $8B, $08, $00, $00, $00, $00, $00, $02, $03, $95, $95, $41, $6A, $C3, $30,
    $10, $45, $AF, $62, $B4, $0E, $46, $7F, $64, $59, $76, $AF, $12, $B2, $70, $1A,
    $35, $98, $26, $69, $71, $9C, $55, $E9, $DD, $A3, $40, $0B, $8D, $A6, $33, $48,
    $3B, $59, $D8, $1F, $BD, $E1, $7D, $79, $FB, $65, $E6, $83, $79, $69, $EC, $A6,
    $31, $97, $E9, $1C, $D3, $D2, $CC, $6B, $3C, $37, $D6, $A4, $9D, $75, $3A, $5E,
    $D3, $CE, $D6, $2C, $F1, $60, $76, $69, $E3, $73, $99, $5F, $1F, $EF, $D8, $F6,
    $F1, $C1, $C7, $7B, $5A, $AE, $CB, $2D, $7E, $6F, $9A, $9F, $1C, $E4, $39, $60,
    $39, $E9, $F9, $B8, $C4, $78, $79, $0A, $44, $4B, $FE, $37, $F1, $6D, $3A, $5D,
    $FF, $44, $52, $1E, $49, $72, $64, $5A, $EC, $4F, $B7, $F8, $14, $4D, $AD, $FF,
    $FF, $AC, $2E, $0F, $76, $2A, $B3, $6B, $83, $74, $C4, $2E, $4F, $EA, $CA, $A8,
    $BD, $34, $46, $9F, $07, $FA, $3A, $E6, $5E, $1E, $67, $9F, $47, $F7, $2A, $75,
    $90, $A6, $17, $F2, $9C, $50, $C6, $3C, $C8, $63, $1C, $F2, $C8, $A1, $8E, $1A,
    $A2, $96, $63, $9E, $3C, $AA, $D0, $50, $74, $04, $AB, $0A, $6C, $A1, $E3, $A2,
    $89, $E0, $B5, $41, $25, $BA, $62, $27, $58, $83, $40, $3A, $BE, $E8, $25, $58,
    $67, $E0, $0A, $E1, $15, $25, $C1, $FA, $83, $AE, $12, $5F, $D4, $14, $AC, $4A,
    $F0, $3A, $BC, $22, $28, $58, $79, $D0, $97, $E1, $93, $7C, $63, $B2, $22, $21,
    $54, $5E, $70, $9A, $AD, $AC, $53, $18, $54, $7C, $92, $25, $65, $25, $C2, $58,
    $08, $AF, $C8, $49, $AC, $4E, $64, $2B, $F1, $45, $5B, $89, $D5, $8A, $A0, $C3,
    $2B, $92, $12, $FF, $0F, $51, $21, $BE, $28, $27, $B1, $3A, $91, $AB, $84, $E7,
    $B6, $EE, $EE, $63, $6D, $EC, $E9, $D4, $07, $00, $00
};

u8 gzSmall9[45] = {
    $1F, $8B, $08, $00, $00, $00, $00, $00, $02, $03, $AB, $56, $4A, $54, $B2, $8A,
    $36, $D4, $31, $D2, $31, $8E, $D5, $51, $4A, $52, $B2, $52, $4A, $4E, $4C, $3B,
    $BC, $52, $A9, $16, $00, $2F, $0F, $37, $3D, $19, $00, $00, $00
};

u8 gzStored[323] = {
    $1F, $8B, $08, $00, $00, $00, $00, $00, $04, $FF, $01, $2C, $01, $D3, $FE, $5B,
    $7B, $22, $69, $64, $22, $3A, $20, $30, $2C, $20, $22, $6E, $61, $6D, $65, $22,
    $3A, $20, $22, $69, $74, $65, $6D, $20, $30, $22, $2C, $20, $22, $74, $61, $67,
    $73, $22, $3A, $20, $5B, $22, $72, $65, $64, $22, $5D, $2C, $20, $22, $70, $72,
    $69, $63, $65, $22, $3A, $20, $30, $2E, $30, $2C, $20, $22, $6F, $6B, $22, $3A,
    $20, $74, $72, $75, $65, $7D, $2C, $20, $7B, $22, $69, $64, $22, $3A, $20, $31,
    $2C, $20, $22, $6E, $61, $6D, $65, $22, $3A, $20, $22, $69, $74, $65, $6D, $20,
    $31, $22, $2C, $20, $22, $74, $61, $67, $73, $22, $3A, $20, $5B, $22, $72, $65,
    $64, $22, $2C, $20, $22, $67, $72, $65, $65, $6E, $22, $5D, $2C, $20, $22, $70,
    $72, $69, $63, $65, $22, $3A, $20, $31, $2E, $32, $35, $2C, $20, $22, $6F, $6B,
    $22, $3A, $20, $66, $61, $6C, $73, $65, $7D, $2C, $20, $7B, $22, $69, $64, $22,
    $3A, $20, $32, $2C, $20, $22, $6E, $61, $6D, $65, $22, $3A, $20, $22, $69, $74,
    $65, $6D, $20, $32, $22, $2C, $20, $22, $74, $61, $67, $73, $22, $3A, $20, $5B,
    $22, $72, $65, $64, $22, $2C, $20, $22, $67, $72, $65, $65, $6E, $22, $2C, $20,
    $22, $62, $6C, $75, $65, $22, $5D, $2C, $20, $22, $70, $72, $69, $63, $65, $22,
    $3A, $20, $32, $2E, $35, $2C, $20, $22, $6F, $6B, $22, $3A, $20, $74, $72, $75,
    $65, $7D, $2C, $20, $7B, $22, $69, $64, $22, $3A, $20, $33, $2C, $20, $22, $6E,
    $61, $6D, $65, $22, $3A, $20, $22, $69, $74, $65, $6D, $20, $33, $22, $2C, $20,
    $22, $74, $61, $67, $73, $22, $3A, $20, $5B, $22, $72, $65, $64, $22, $5D, $2C,
    $20, $22, $70, $72, $69, $63, $65, $22, $3A, $20, $33, $DB, $81, $10, $4E, $2C,
    $01, $00, $00
};

u8 gzNamed[325] = {
    $1F, $8B, $08, $08, $00, $00, $00, $00, $02, $FF, $64, $61, $74, $61, $2E, $6A,
    $73, $6F, $6E, $00, $95, $95, $41, $6A, $C3, $30, $10, $45, $AF, $62, $B4, $0E,
    $46, $7F, $64, $59, $76, $AF, $12, $B2, $70, $1A, $35, $98, $26, $69, $71, $9C,
    $55, $E9, $DD, $A3, $40, $0B, $8D, $A6, $33, $48, $3B, $59, $D8, $1F, $BD, $E1,
    $7D, $79, $FB, $65, $E6, $83, $79, $69, $EC, $A6, $31, $97, $E9, $1C, $D3, $D2,
    $CC, $6B, $3C, $37, $D6, $A4, $9D, $75, $3A, $5E, $D3, $CE, $D6, $2C, $F1, $60,
    $76, $69, $E3, $73, $99, $5F, $1F, $EF, $D8, $F6, $F1, $C1, $C7, $7B, $5A, $AE,
    $CB, $2D, $7E, $6F, $9A, $9F, $1C, $E4, $39, $60, $39, $E9, $F9, $B8, $C4, $78,
    $79, $0A, $44, $4B, $FE, $37, $F1, $6D, $3A, $5D, $FF, $44, $52, $1E, $49, $72,
    $64, $5A, $EC, $4F, $B7, $F8, $14, $4D, $AD, $FF, $FF, $AC, $2E, $0F, $76, $2A,
    $B3, $6B, $83, $74, $C4, $2E, $4F, $EA, $CA, $A8, $BD, $34, $46, $9F, $07, $FA,
    $3A, $E6, $5E, $1E, $67, $9F, $47, $F7, $2A, $75, $90, $A6, $17, $F2, $9C, $50,
    $C6, $3C, $C8, $63, $1C, $F2, $C8, $A1, $8E, $1A, $A2, $96, $63, $9E, $3C, $AA,
    $D0, $50, $74, $04, $AB, $0A, $6C, $A1, $E3, $A2, $89, $E0, $B5, $41, $25, $BA,
    $62, $27, $58, $83, $40, $3A, $BE, $E8, $25, $58, $67, $E0, $0A, $E1, $15, $25,
    $C1, $FA, $83, $AE, $12, $5F, $D4, $14, $AC, $4A, $F0, $3A, $BC, $22, $28, $58,
    $79, $D0, $97, $E1, $93, $7C, $63, $B2, $22, $21, $54, $5E, $70, $9A, $AD, $AC,
    $53, $18, $54, $7C, $92, $25, $65, $25, $C2, $58, $08, $AF, $C8, $49, $AC, $4E,
    $64, $2B, $F1, $45, $5B, $89, $D5, $8A, $A0, $C3, $2B, $92, $12, $FF, $0F, $51,
    $21, $BE, $28, $27, $B1, $3A, $91, $AB, $84, $E7, $B6, $EE, $EE, $63, $6D, $EC,
    $E9, $D4, $07, $00, $00
};

void check(string name, u8* gz, u32 n, u8* want, u32 wantLen)
{
    try
        {
        Data* out = Coder.gunzip(Data.withBytes(gz, n));
        bool same = out.length() == wantLen;
        u8* b = out.bytes();
        for (u32 i = (u32)0; same && i < wantLen; i++)
            same = b[i] == want[i];
        Stdio.printf("  %s: %d bytes, %s\n", name, (i32)out.length(), same ? "match" : "DIFFERENT");
        }
    catch (CoderError e)
        {
        Stdio.printf("  %s: UNEXPECTED %s\n", name, e.message().cString());
        }
}

void expectFailure(string name, Data* gz)
{
    try
        {
        Data* out = Coder.gunzip(gz);
        Stdio.printf("  %s: UNEXPECTEDLY decoded %d bytes\n", name, (i32)out.length());
        }
    catch (CoderError e)
        {
        Stdio.printf("  %s: %s\n", name, e.message().cString());
        }
}

bool roundTrip(Data* d, u8 level)
{
    Data* z = Coder.gzip(d, level);
    try
        {
        Data* back = Coder.gunzip(z);
        return back.equals(d);
        }
    catch (CoderError e)
        {
        Stdio.printf("  level %d: %s\n", (i32)level, e.message().cString());
        }
    return false;
}

void main(void)
{
    Stdio.printf("T1 crc\n");
    u32 crc = Coder.crc32("123456789", (u32)9);
    Stdio.printf("  %s\n", (crc == (u32)0xCBF43926) ? "CBF43926" : "WRONG");

    Stdio.printf("T2 reference streams\n");
    u8* big = (u8*)bigJson;
    check("gzip -1", &gzBig1[0], (u32)gzBig1.length, big, bigLen);
    check("gzip -9", &gzBig9[0], (u32)gzBig9.length, big, bigLen);
    check("gzip -9 short", &gzSmall9[0], (u32)gzSmall9.length, (u8*)smallJson, smallLen);
    check("stored", &gzStored[0], (u32)gzStored.length, big, (u32)300);
    check("named", &gzNamed[0], (u32)gzNamed.length, big, bigLen);

    Stdio.printf("T3 our gzip\n");
    Data* text = Data.withBytes(big, bigLen);
    Data* runs = new Data();
    for (u32 i = (u32)0; i < (u32)5000; i++)
        runs.appendByte((u8)((i / (u32)250) & (u32)3));
    bool allText = true;
    bool allRuns = true;
    for (u8 level = (u8)0; level <= (u8)9; level++)
        {
        if (!roundTrip(text, level))
            allText = false;
        if (!roundTrip(runs, level))
            allRuns = false;
        }
    Stdio.printf("  text at 0-9: %s\n", allText ? "ok" : "FAILED");
    Stdio.printf("  runs at 0-9: %s\n", allRuns ? "ok" : "FAILED");
    Stdio.printf("  empty: %s\n", roundTrip(new Data(), (u8)6) ? "ok" : "FAILED");
    Data* z9 = Coder.gzip(runs, (u8)9);
    Stdio.printf("  5000 run bytes under 200 at level 9: %s\n", (z9.length() < (u32)200) ? "yes" : "NO");

    Stdio.printf("T4 damage\n");
    Data* bad = Data.withBytes(&gzBig9[0], (u32)gzBig9.length);
    bad.setByteAt((u32)100, bad.byteAt((u32)100) ^ (u8)$10);
    expectFailure("flipped bit", bad);
    Data* badCrc = Data.withBytes(&gzBig9[0], (u32)gzBig9.length);
    u32 at = badCrc.length() - (u32)8;
    badCrc.setByteAt(at, badCrc.byteAt(at) ^ (u8)1);
    expectFailure("wrong CRC", badCrc);
    expectFailure("truncated", Data.withBytes(&gzBig9[0], (u32)100));
    expectFailure("not gzip", Data.withString(String.withCString("{\"hello\":1} padding padding")));
    Stdio.printf("done\n");
}
