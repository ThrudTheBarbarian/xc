// Xa6502.xc — the 6502 opcode table, in xtc.
// =================================================================
//
// self-hosting M24, a port of `XA6502`. The official 6502 instruction set plus
// the xt CPU's additions: SP-relative addressing, the stack-indirect forms, the
// PSH/PLL prologue helpers, direct push and pop of X and Y, and BRA.
//
// The table is a flat list of (mnemonic, mode, opcode) triples, exactly as the
// original spells it. A missing combination is not an oversight to be papered
// over — `LDA (nn),X` does not exist — so the lookup returns -1 and the caller
// reports it by name.

#import "Foundation.xc"

#define AM_IMPLIED 0
#define AM_ACCUMULATOR 1
#define AM_IMMEDIATE 2
#define AM_ZEROPAGE 3
#define AM_ZEROPAGEX 4
#define AM_ZEROPAGEY 5
#define AM_ABSOLUTE 6
#define AM_ABSOLUTEX 7
#define AM_ABSOLUTEY 8
#define AM_INDIRECT 9
#define AM_INDEXEDINDIRECTX 10
#define AM_INDIRECTINDEXEDY 11
#define AM_RELATIVE 12
#define AM_SPRELATIVE 13
#define AM_STACKADJUST 14
#define AM_SPINDIRECTINDEXEDY 15
#define AM_SPINDEXEDX 16

class Xa6502
    {
    Array* _mn;   // String@
    Array* _mode; // Number@
    Array* _op;   // Number@

    void init(void)
        {
        _mn = new Array();
        _mode = new Array();
        _op = new Array();
        buildTable();
        }

    void add(String* m, u32 mode, u32 op)
        {
        _mn.add((Object*)m);
        _mode.add((Object*)Number.withU32(mode));
        _op.add((Object*)Number.withU32(op));
        }

    // The opcode byte for a mnemonic and mode, or -1 when the combination does
    // not exist.
    i32 opcodeFor(String* mnemonic, u32 mode)
        {
        String* up = mnemonic.uppercased();
        for (u32 i = (u32)0; i < _mn.count(); i = i + (u32)1)
            {
            if (((Number*)_mode.get(i)).asU32() != mode)
                continue;
            if (!((String*)_mn.get(i)).equals(up))
                continue;
            return (i32)((Number*)_op.get(i)).asU32();
            }
        return (i32)-1;
        }

    bool isValidMnemonic(String* mnemonic)
        {
        String* up = mnemonic.uppercased();
        for (u32 i = (u32)0; i < _mn.count(); i = i + (u32)1)
            if (((String*)_mn.get(i)).equals(up))
                return true;
        return false;
        }

    static bool isBranchMnemonic(String* mnemonic)
        {
        String* m = mnemonic.uppercased();
        return m.equals(String.withCString("BCC")) || m.equals(String.withCString("BCS")) || m.equals(String.withCString("BEQ")) || m.equals(String.withCString("BMI")) || m.equals(String.withCString("BNE")) || m.equals(String.withCString("BPL")) || m.equals(String.withCString("BVC")) || m.equals(String.withCString("BVS")) || m.equals(String.withCString("BRA"));
        }

    // The instruction's byte size for a mode: 1, 2 or 3.
    static u32 byteSizeForMode(u32 mode)
        {
        if (mode == (u32)AM_IMPLIED || mode == (u32)AM_ACCUMULATOR)
            return (u32)1;
        if (mode == (u32)AM_ABSOLUTE || mode == (u32)AM_ABSOLUTEX || mode == (u32)AM_ABSOLUTEY || mode == (u32)AM_INDIRECT)
            return (u32)3;
        return (u32)2;
        }

    // Split into chunks purely for the arm64 frame budget: one long run of
    // string literals builds more temporaries than a single frame can hold.
    void buildTable(void)
        {
        buildTable0();
        buildTable1();
        buildTable2();
        buildTable3();
        buildTable4();
        buildTable5();
        buildTable6();
        buildTable7();
        }

    void buildTable0(void)
        {
        add(String.withCString("ADC"), (u32)AM_IMMEDIATE, (u32)$69);
        add(String.withCString("ADC"), (u32)AM_ZEROPAGE, (u32)$65);
        add(String.withCString("ADC"), (u32)AM_ZEROPAGEX, (u32)$75);
        add(String.withCString("ADC"), (u32)AM_ABSOLUTE, (u32)$6D);
        add(String.withCString("ADC"), (u32)AM_ABSOLUTEX, (u32)$7D);
        add(String.withCString("ADC"), (u32)AM_ABSOLUTEY, (u32)$79);
        add(String.withCString("ADC"), (u32)AM_INDEXEDINDIRECTX, (u32)$61);
        add(String.withCString("ADC"), (u32)AM_INDIRECTINDEXEDY, (u32)$71);
        add(String.withCString("AND"), (u32)AM_IMMEDIATE, (u32)$29);
        add(String.withCString("AND"), (u32)AM_ZEROPAGE, (u32)$25);
        add(String.withCString("AND"), (u32)AM_ZEROPAGEX, (u32)$35);
        add(String.withCString("AND"), (u32)AM_ABSOLUTE, (u32)$2D);
        add(String.withCString("AND"), (u32)AM_ABSOLUTEX, (u32)$3D);
        add(String.withCString("AND"), (u32)AM_ABSOLUTEY, (u32)$39);
        add(String.withCString("AND"), (u32)AM_INDEXEDINDIRECTX, (u32)$21);
        add(String.withCString("AND"), (u32)AM_INDIRECTINDEXEDY, (u32)$31);
        add(String.withCString("ASL"), (u32)AM_ACCUMULATOR, (u32)$0A);
        add(String.withCString("ASL"), (u32)AM_ZEROPAGE, (u32)$06);
        add(String.withCString("ASL"), (u32)AM_ZEROPAGEX, (u32)$16);
        add(String.withCString("ASL"), (u32)AM_ABSOLUTE, (u32)$0E);
        add(String.withCString("ASL"), (u32)AM_ABSOLUTEX, (u32)$1E);
        add(String.withCString("BCC"), (u32)AM_RELATIVE, (u32)$90);
        add(String.withCString("BCS"), (u32)AM_RELATIVE, (u32)$B0);
        add(String.withCString("BEQ"), (u32)AM_RELATIVE, (u32)$F0);
        }

    void buildTable1(void)
        {
        add(String.withCString("BMI"), (u32)AM_RELATIVE, (u32)$30);
        add(String.withCString("BNE"), (u32)AM_RELATIVE, (u32)$D0);
        add(String.withCString("BPL"), (u32)AM_RELATIVE, (u32)$10);
        add(String.withCString("BVC"), (u32)AM_RELATIVE, (u32)$50);
        add(String.withCString("BVS"), (u32)AM_RELATIVE, (u32)$70);
        add(String.withCString("BIT"), (u32)AM_ZEROPAGE, (u32)$24);
        add(String.withCString("BIT"), (u32)AM_ABSOLUTE, (u32)$2C);
        add(String.withCString("BRK"), (u32)AM_IMPLIED, (u32)$00);
        add(String.withCString("CLC"), (u32)AM_IMPLIED, (u32)$18);
        add(String.withCString("CLD"), (u32)AM_IMPLIED, (u32)$D8);
        add(String.withCString("CLI"), (u32)AM_IMPLIED, (u32)$58);
        add(String.withCString("CLV"), (u32)AM_IMPLIED, (u32)$B8);
        add(String.withCString("CMP"), (u32)AM_IMMEDIATE, (u32)$C9);
        add(String.withCString("CMP"), (u32)AM_ZEROPAGE, (u32)$C5);
        add(String.withCString("CMP"), (u32)AM_ZEROPAGEX, (u32)$D5);
        add(String.withCString("CMP"), (u32)AM_ABSOLUTE, (u32)$CD);
        add(String.withCString("CMP"), (u32)AM_ABSOLUTEX, (u32)$DD);
        add(String.withCString("CMP"), (u32)AM_ABSOLUTEY, (u32)$D9);
        add(String.withCString("CMP"), (u32)AM_INDEXEDINDIRECTX, (u32)$C1);
        add(String.withCString("CMP"), (u32)AM_INDIRECTINDEXEDY, (u32)$D1);
        add(String.withCString("CPX"), (u32)AM_IMMEDIATE, (u32)$E0);
        add(String.withCString("CPX"), (u32)AM_ZEROPAGE, (u32)$E4);
        add(String.withCString("CPX"), (u32)AM_ABSOLUTE, (u32)$EC);
        add(String.withCString("CPY"), (u32)AM_IMMEDIATE, (u32)$C0);
        }

    void buildTable2(void)
        {
        add(String.withCString("CPY"), (u32)AM_ZEROPAGE, (u32)$C4);
        add(String.withCString("CPY"), (u32)AM_ABSOLUTE, (u32)$CC);
        add(String.withCString("DEC"), (u32)AM_ZEROPAGE, (u32)$C6);
        add(String.withCString("DEC"), (u32)AM_ZEROPAGEX, (u32)$D6);
        add(String.withCString("DEC"), (u32)AM_ABSOLUTE, (u32)$CE);
        add(String.withCString("DEC"), (u32)AM_ABSOLUTEX, (u32)$DE);
        add(String.withCString("DEX"), (u32)AM_IMPLIED, (u32)$CA);
        add(String.withCString("DEY"), (u32)AM_IMPLIED, (u32)$88);
        add(String.withCString("EOR"), (u32)AM_IMMEDIATE, (u32)$49);
        add(String.withCString("EOR"), (u32)AM_ZEROPAGE, (u32)$45);
        add(String.withCString("EOR"), (u32)AM_ZEROPAGEX, (u32)$55);
        add(String.withCString("EOR"), (u32)AM_ABSOLUTE, (u32)$4D);
        add(String.withCString("EOR"), (u32)AM_ABSOLUTEX, (u32)$5D);
        add(String.withCString("EOR"), (u32)AM_ABSOLUTEY, (u32)$59);
        add(String.withCString("EOR"), (u32)AM_INDEXEDINDIRECTX, (u32)$41);
        add(String.withCString("EOR"), (u32)AM_INDIRECTINDEXEDY, (u32)$51);
        add(String.withCString("INC"), (u32)AM_ZEROPAGE, (u32)$E6);
        add(String.withCString("INC"), (u32)AM_ZEROPAGEX, (u32)$F6);
        add(String.withCString("INC"), (u32)AM_ABSOLUTE, (u32)$EE);
        add(String.withCString("INC"), (u32)AM_ABSOLUTEX, (u32)$FE);
        add(String.withCString("INX"), (u32)AM_IMPLIED, (u32)$E8);
        add(String.withCString("INY"), (u32)AM_IMPLIED, (u32)$C8);
        add(String.withCString("JMP"), (u32)AM_ABSOLUTE, (u32)$4C);
        add(String.withCString("JMP"), (u32)AM_INDIRECT, (u32)$6C);
        }

    void buildTable3(void)
        {
        add(String.withCString("JSR"), (u32)AM_ABSOLUTE, (u32)$20);
        add(String.withCString("LDA"), (u32)AM_IMMEDIATE, (u32)$A9);
        add(String.withCString("LDA"), (u32)AM_ZEROPAGE, (u32)$A5);
        add(String.withCString("LDA"), (u32)AM_ZEROPAGEX, (u32)$B5);
        add(String.withCString("LDA"), (u32)AM_ABSOLUTE, (u32)$AD);
        add(String.withCString("LDA"), (u32)AM_ABSOLUTEX, (u32)$BD);
        add(String.withCString("LDA"), (u32)AM_ABSOLUTEY, (u32)$B9);
        add(String.withCString("LDA"), (u32)AM_INDEXEDINDIRECTX, (u32)$A1);
        add(String.withCString("LDA"), (u32)AM_INDIRECTINDEXEDY, (u32)$B1);
        add(String.withCString("LDX"), (u32)AM_IMMEDIATE, (u32)$A2);
        add(String.withCString("LDX"), (u32)AM_ZEROPAGE, (u32)$A6);
        add(String.withCString("LDX"), (u32)AM_ZEROPAGEY, (u32)$B6);
        add(String.withCString("LDX"), (u32)AM_ABSOLUTE, (u32)$AE);
        add(String.withCString("LDX"), (u32)AM_ABSOLUTEY, (u32)$BE);
        add(String.withCString("LDY"), (u32)AM_IMMEDIATE, (u32)$A0);
        add(String.withCString("LDY"), (u32)AM_ZEROPAGE, (u32)$A4);
        add(String.withCString("LDY"), (u32)AM_ZEROPAGEX, (u32)$B4);
        add(String.withCString("LDY"), (u32)AM_ABSOLUTE, (u32)$AC);
        add(String.withCString("LDY"), (u32)AM_ABSOLUTEX, (u32)$BC);
        add(String.withCString("LSR"), (u32)AM_ACCUMULATOR, (u32)$4A);
        add(String.withCString("LSR"), (u32)AM_ZEROPAGE, (u32)$46);
        add(String.withCString("LSR"), (u32)AM_ZEROPAGEX, (u32)$56);
        add(String.withCString("LSR"), (u32)AM_ABSOLUTE, (u32)$4E);
        add(String.withCString("LSR"), (u32)AM_ABSOLUTEX, (u32)$5E);
        }

    void buildTable4(void)
        {
        add(String.withCString("NOP"), (u32)AM_IMPLIED, (u32)$EA);
        add(String.withCString("ORA"), (u32)AM_IMMEDIATE, (u32)$09);
        add(String.withCString("ORA"), (u32)AM_ZEROPAGE, (u32)$05);
        add(String.withCString("ORA"), (u32)AM_ZEROPAGEX, (u32)$15);
        add(String.withCString("ORA"), (u32)AM_ABSOLUTE, (u32)$0D);
        add(String.withCString("ORA"), (u32)AM_ABSOLUTEX, (u32)$1D);
        add(String.withCString("ORA"), (u32)AM_ABSOLUTEY, (u32)$19);
        add(String.withCString("ORA"), (u32)AM_INDEXEDINDIRECTX, (u32)$01);
        add(String.withCString("ORA"), (u32)AM_INDIRECTINDEXEDY, (u32)$11);
        add(String.withCString("PHA"), (u32)AM_IMPLIED, (u32)$48);
        add(String.withCString("PHP"), (u32)AM_IMPLIED, (u32)$08);
        add(String.withCString("PLA"), (u32)AM_IMPLIED, (u32)$68);
        add(String.withCString("PLP"), (u32)AM_IMPLIED, (u32)$28);
        add(String.withCString("ROL"), (u32)AM_ACCUMULATOR, (u32)$2A);
        add(String.withCString("ROL"), (u32)AM_ZEROPAGE, (u32)$26);
        add(String.withCString("ROL"), (u32)AM_ZEROPAGEX, (u32)$36);
        add(String.withCString("ROL"), (u32)AM_ABSOLUTE, (u32)$2E);
        add(String.withCString("ROL"), (u32)AM_ABSOLUTEX, (u32)$3E);
        add(String.withCString("ROR"), (u32)AM_ACCUMULATOR, (u32)$6A);
        add(String.withCString("ROR"), (u32)AM_ZEROPAGE, (u32)$66);
        add(String.withCString("ROR"), (u32)AM_ZEROPAGEX, (u32)$76);
        add(String.withCString("ROR"), (u32)AM_ABSOLUTE, (u32)$6E);
        add(String.withCString("ROR"), (u32)AM_ABSOLUTEX, (u32)$7E);
        add(String.withCString("RTI"), (u32)AM_IMPLIED, (u32)$40);
        }

    void buildTable5(void)
        {
        add(String.withCString("RTS"), (u32)AM_IMPLIED, (u32)$60);
        add(String.withCString("SBC"), (u32)AM_IMMEDIATE, (u32)$E9);
        add(String.withCString("SBC"), (u32)AM_ZEROPAGE, (u32)$E5);
        add(String.withCString("SBC"), (u32)AM_ZEROPAGEX, (u32)$F5);
        add(String.withCString("SBC"), (u32)AM_ABSOLUTE, (u32)$ED);
        add(String.withCString("SBC"), (u32)AM_ABSOLUTEX, (u32)$FD);
        add(String.withCString("SBC"), (u32)AM_ABSOLUTEY, (u32)$F9);
        add(String.withCString("SBC"), (u32)AM_INDEXEDINDIRECTX, (u32)$E1);
        add(String.withCString("SBC"), (u32)AM_INDIRECTINDEXEDY, (u32)$F1);
        add(String.withCString("SEC"), (u32)AM_IMPLIED, (u32)$38);
        add(String.withCString("SED"), (u32)AM_IMPLIED, (u32)$F8);
        add(String.withCString("SEI"), (u32)AM_IMPLIED, (u32)$78);
        add(String.withCString("STA"), (u32)AM_ZEROPAGE, (u32)$85);
        add(String.withCString("STA"), (u32)AM_ZEROPAGEX, (u32)$95);
        add(String.withCString("STA"), (u32)AM_ABSOLUTE, (u32)$8D);
        add(String.withCString("STA"), (u32)AM_ABSOLUTEX, (u32)$9D);
        add(String.withCString("STA"), (u32)AM_ABSOLUTEY, (u32)$99);
        add(String.withCString("STA"), (u32)AM_INDEXEDINDIRECTX, (u32)$81);
        add(String.withCString("STA"), (u32)AM_INDIRECTINDEXEDY, (u32)$91);
        add(String.withCString("STX"), (u32)AM_ZEROPAGE, (u32)$86);
        add(String.withCString("STX"), (u32)AM_ZEROPAGEY, (u32)$96);
        add(String.withCString("STX"), (u32)AM_ABSOLUTE, (u32)$8E);
        add(String.withCString("STY"), (u32)AM_ZEROPAGE, (u32)$84);
        add(String.withCString("STY"), (u32)AM_ZEROPAGEX, (u32)$94);
        }

    void buildTable6(void)
        {
        add(String.withCString("STY"), (u32)AM_ABSOLUTE, (u32)$8C);
        add(String.withCString("TAX"), (u32)AM_IMPLIED, (u32)$AA);
        add(String.withCString("TAY"), (u32)AM_IMPLIED, (u32)$A8);
        add(String.withCString("TSX"), (u32)AM_IMPLIED, (u32)$BA);
        add(String.withCString("TXA"), (u32)AM_IMPLIED, (u32)$8A);
        add(String.withCString("TXS"), (u32)AM_IMPLIED, (u32)$9A);
        add(String.withCString("TYA"), (u32)AM_IMPLIED, (u32)$98);
        add(String.withCString("LDA"), (u32)AM_SPRELATIVE, (u32)$B2);
        add(String.withCString("STA"), (u32)AM_SPRELATIVE, (u32)$92);
        add(String.withCString("LDX"), (u32)AM_SPRELATIVE, (u32)$42);
        add(String.withCString("STX"), (u32)AM_SPRELATIVE, (u32)$02);
        add(String.withCString("LDY"), (u32)AM_SPRELATIVE, (u32)$52);
        add(String.withCString("STY"), (u32)AM_SPRELATIVE, (u32)$12);
        add(String.withCString("ADC"), (u32)AM_SPRELATIVE, (u32)$72);
        add(String.withCString("SBC"), (u32)AM_SPRELATIVE, (u32)$F2);
        add(String.withCString("CMP"), (u32)AM_SPRELATIVE, (u32)$D2);
        add(String.withCString("LDA"), (u32)AM_SPINDIRECTINDEXEDY, (u32)$03);
        add(String.withCString("STA"), (u32)AM_SPINDIRECTINDEXEDY, (u32)$13);
        add(String.withCString("LDA"), (u32)AM_SPINDEXEDX, (u32)$23);
        add(String.withCString("STA"), (u32)AM_SPINDEXEDX, (u32)$33);
        add(String.withCString("ADD"), (u32)AM_STACKADJUST, (u32)$22);
        add(String.withCString("PSH"), (u32)AM_IMMEDIATE, (u32)$32);
        add(String.withCString("PLL"), (u32)AM_IMMEDIATE, (u32)$62);
        add(String.withCString("PHX"), (u32)AM_IMPLIED, (u32)$44);
        }

    void buildTable7(void)
        {
        add(String.withCString("PHY"), (u32)AM_IMPLIED, (u32)$54);
        add(String.withCString("PLX"), (u32)AM_IMPLIED, (u32)$64);
        add(String.withCString("PLY"), (u32)AM_IMPLIED, (u32)$74);
        add(String.withCString("BRA"), (u32)AM_RELATIVE, (u32)$80);
        }
    }
