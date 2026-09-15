// xcc runtime library.
//
// Copyright (C) 2026 ThrudTheBarbarian@compile-xc.org
//
// This file is part of the xcc runtime library: the code that is combined
// with a program when xcc compiles it. It is free software; you can
// redistribute it and/or modify it under the terms of the GNU General Public
// License as published by the Free Software Foundation, either version 3 of
// the License, or (at your option) any later version.
//
// Under Section 7 of GPL version 3, you are granted additional permissions
// described in the GCC Runtime Library Exception, version 3.1, as published
// by the Free Software Foundation -- see COPYING.RUNTIME in this directory's
// parent.
//
// The effect of that exception is the point: a program compiled by xcc
// contains parts of this file, and the exception is what leaves that program
// under whatever licence its author chooses, including a proprietary one.
//
// This file is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE.

// symbols.xc — Atari 8-bit memory map symbols
// ==============================================
// Usage: #import <symbols.xc>
//
// Sources: Mapping the Atari (atariarchives.org/mapping)
//          Atari OS/hardware reference manuals

// ── Page 0: OS zero-page variables ──────────────────────────────

#define LINZBS ((u16)$00) // LINBUG RAM, also free if not debugging
#define CASINI ((u16)$02) // cassette initialisation vector
#define RAMLO ((u16)$04)  // RAM pointer for memory test
#define TRAMSZ ((u8)$06)  // temporary RAM size
#define TSTDAT ((u8)$07)  // RAM test data register
#define WARMST ((u8)$08)  // warm start flag (0=cold, non-0=warm)
#define BOOTQ ((u8)$09)   // boot completion flag
#define DOSVEC ((u16)$0A) // DOS start vector
#define DOSINI ((u16)$0C) // DOS init address
#define APPMHI ((u16)$0E) // application memory high limit
#define POKMSK ((u8)$10)  // IRQEN shadow (POKEY interrupt mask)
#define BRKKEY ((u8)$11)  // break key flag
#define RTCLOK ((u8)$12)  // real-time clock (3 bytes, MSB first)
#define BUFADR ((u16)$15) // SIO buffer address pointer
#define ICCOMT ((u8)$17)  // CIO command temp
#define DSKFMS ((u16)$18) // disk file manager pointer
#define DSKUTL ((u16)$1A) // disk utilities pointer

// ── Page 0: CIO zero-page ──────────────────────────────────────

#define ICHIDZ ((u8)$20)  // CIO handler index (zero-page)
#define ICDNOZ ((u8)$21)  // CIO device number
#define ICCOMZ ((u8)$22)  // CIO command byte
#define ICSTAZ ((u8)$23)  // CIO status
#define ICBALZ ((u16)$24) // CIO buffer address
#define ICPTLZ ((u16)$26) // CIO put-byte routine address
#define ICBLLZ ((u16)$28) // CIO buffer length
#define ICAX1Z ((u8)$2A)  // CIO aux byte 1
#define ICAX2Z ((u8)$2B)  // CIO aux byte 2

// ── Page 0: SIO and misc ───────────────────────────────────────

#define STATUS ((u8)$30)  // SIO status
#define CHKSUM ((u8)$31)  // SIO checksum
#define BUFRLO ((u16)$32) // SIO buffer pointer
#define BFENLO ((u16)$34) // SIO buffer end pointer
#define CRETRY ((u8)$36)  // SIO command retry count
#define DRETRY ((u8)$37)  // SIO device retry count
#define BUFRFL ((u8)$38)  // SIO buffer full flag
#define RECVDN ((u8)$39)  // SIO receive done flag
#define XMTDON ((u8)$3A)  // SIO transmit done flag
#define CHKSNT ((u8)$3B)  // SIO checksum sent flag
#define NOCKSM ((u8)$3C)  // SIO no-checksum flag

#define SOUNDR ((u8)$41) // noisy I/O flag (0=quiet)
#define CRITIC ((u8)$42) // critical section flag
#define ZBUFP ((u16)$43) // cassette buffer pointer
#define ZDRVA ((u16)$45) // disk sector buffer address
#define ZSBA ((u16)$47)  // sector buffer address pointer
#define ERRNO ((u8)$49)  // SIO error number
#define CKEY ((u8)$4A)   // start key flag
#define CASSBT ((u8)$4B) // cassette boot flag
#define DSTAT ((u8)$4C)  // disk status

// ── Page 0: Display handler ────────────────────────────────────

#define ATRACT ((u8)$4D)  // attract mode timer
#define DRKMSK ((u8)$4E)  // dark attract mask
#define COLRSH ((u8)$4F)  // attract colour shift
#define TEMP ((u8)$50)    // temp register
#define HOLD1 ((u8)$51)   // temp register
#define LMARGN ((u8)$52)  // left margin (default 2)
#define RMARGN ((u8)$53)  // right margin (default 39)
#define ROWCRS ((u8)$54)  // cursor row
#define COLCRS ((u16)$55) // cursor column (2 bytes)
#define DINDEX ((u8)$57)  // display mode (GR. number)
#define SAVMSC ((u16)$58) // screen memory address
#define OLDROW ((u8)$5A)  // previous cursor row
#define OLDCOL ((u16)$5B) // previous cursor column
#define OLDCHR ((u8)$5D)  // character under cursor
#define OLDADR ((u16)$5E) // cursor memory address
#define NEWROW ((u8)$60)  // point destination row
#define NEWCOL ((u16)$61) // point destination column
#define LOGCOL ((u8)$63)  // logical line cursor column
#define ADRESS ((u16)$64) // temp address
#define RAMTOP ((u8)$6A)  // RAM size (pages)
#define BUFCNT ((u8)$6B)  // logical line buffer count
#define BUFSTR ((u16)$6C) // editor buffer start
#define BITMSK ((u8)$6E)  // bit mask
#define SHFAMT ((u8)$6F)  // shift amount
#define ROWAC ((u16)$70)  // row accumulator
#define COLAC ((u16)$72)  // column accumulator
#define ENDPT ((u16)$74)  // line-draw end point
#define DELTAR ((u8)$76)  // delta row
#define DELTAC ((u16)$77) // delta column
#define ROWINC ((u8)$79)  // row increment (+1 or -1)
#define COLINC ((u8)$7A)  // column increment (+1 or -1)
#define SWPFLG ((u8)$7B)  // split screen swap flag
#define HOLDCH ((u8)$7C)  // held character
#define INSDAT ((u8)$7D)  // insert-mode char under cursor
#define COUNTR ((u16)$7E) // draw counter

// ── Page 0: BASIC and FP ───────────────────────────────────────

#define LOMEM ((u16)$80)  // BASIC low memory pointer
#define VNTP ((u16)$82)   // variable name table pointer
#define VNTD ((u16)$84)   // variable name table end
#define VVTP ((u16)$86)   // variable value table pointer
#define STMTAB ((u16)$88) // BASIC statement table
#define STMCUR ((u16)$8A) // current statement pointer
#define STARP ((u16)$8C)  // string/array table pointer
#define RUNSTK ((u16)$8E) // runtime stack pointer
#define MEMTOP ((u16)$90) // top of BASIC memory

#define STOPLN ((u16)$BA) // stopped line number
#define ERRSAVE ((u8)$C3) // saved error number
#define PTABW ((u8)$C9)   // tab width

// ── Page 0: Floating point registers ────────────────────────────

#define FR0 ((u8)$D4)     // floating point register 0 (6 bytes)
#define FRE ((u8)$DA)     // floating point extra register
#define FR1 ((u8)$E0)     // floating point register 1 (6 bytes)
#define FR2 ((u8)$E6)     // floating point register 2 (6 bytes)
#define FRX ((u8)$EC)     // floating point spare
#define EEXP ((u8)$ED)    // FP exponent value
#define NSIGN ((u8)$EE)   // FP number sign
#define ESIGN ((u8)$EF)   // FP exponent sign
#define FCHRFLG ((u8)$F0) // first char flag
#define DIGRT ((u8)$F1)   // digit counter (right of decimal)
#define CIX ((u8)$F2)     // character index
#define INBUFF ((u16)$F3) // FP input buffer pointer
#define ZTEMP1 ((u16)$F5) // temp register
#define ZTEMP4 ((u16)$F7) // temp register
#define ZTEMP3 ((u16)$F9) // temp register
#define RADFLG ((u8)$FB)  // radix flag (0=hex, $80=decimal)
#define FLPTR ((u16)$FC)  // floating point pointer
#define FPTR2 ((u16)$FE)  // floating point pointer 2

// ── Page 2: OS vectors ($200-$22F) ──────────────────────────────

#define VDSLST ((u16)$200) // display list interrupt vector
#define VPRCED ((u16)$202) // serial proceed line vector
#define VINTER ((u16)$204) // serial interrupt vector
#define VBREAK ((u16)$206) // BRK instruction vector
#define VKEYBD ((u16)$208) // keyboard interrupt vector
#define VSERIN ((u16)$20A) // serial input ready vector
#define VSEROR ((u16)$20C) // serial output ready vector
#define VSEROC ((u16)$20E) // serial output complete vector
#define VTIMR1 ((u16)$210) // POKEY timer 1 vector
#define VTIMR2 ((u16)$212) // POKEY timer 2 vector
#define VTIMR4 ((u16)$214) // POKEY timer 4 vector
#define VIMIRQ ((u16)$216) // IRQ immediate vector
#define CDTMV1 ((u16)$218) // system timer 1 value
#define CDTMV2 ((u16)$21A) // system timer 2 value
#define CDTMV3 ((u16)$21C) // system timer 3 value
#define CDTMV4 ((u16)$21E) // system timer 4 value
#define CDTMV5 ((u16)$220) // system timer 5 value
#define VVBLKI ((u16)$222) // VBI immediate vector
#define VVBLKD ((u16)$224) // VBI deferred vector
#define CDTMA1 ((u16)$226) // timer 1 callback address
#define CDTMA2 ((u16)$228) // timer 2 callback address
#define CDTMF3 ((u8)$22A)  // timer 3 flag
#define SRTIMR ((u8)$22B)  // key auto-repeat timer
#define CDTMF4 ((u8)$22C)  // timer 4 flag
#define CDTMF5 ((u8)$22E)  // timer 5 flag
#define SDMCTL ((u8)$22F)  // DMACTL shadow

// ── Page 2: Display list and screen ─────────────────────────────

#define SDLSTL ((u16)$230) // display list pointer shadow
#define SSKCTL ((u8)$232)  // SKCTL shadow
#define LPENH ((u8)$234)   // light pen horizontal
#define LPENV ((u8)$235)   // light pen vertical
#define GPRIOR ((u8)$26F)  // PRIOR shadow (GTIA mode)

// ── Page 2: Text window and misc ────────────────────────────────

#define TXTROW ((u8)$290)  // text window cursor row
#define TXTCOL ((u16)$291) // text window cursor column
#define TXTMSC ((u8)$294)  // text window screen memory (2 bytes)
#define DMASK ((u8)$2A0)   // display pixel mask

// ── Page 2: Colors ──────────────────────────────────────────────

#define PCOLR0 ((u8)$2C0) // player 0 colour shadow
#define PCOLR1 ((u8)$2C1) // player 1 colour shadow
#define PCOLR2 ((u8)$2C2) // player 2 colour shadow
#define PCOLR3 ((u8)$2C3) // player 3 colour shadow
#define COLOR0 ((u8)$2C4) // playfield 0 colour shadow
#define COLOR1 ((u8)$2C5) // playfield 1 colour shadow
#define COLOR2 ((u8)$2C6) // playfield 2 colour shadow
#define COLOR3 ((u8)$2C7) // playfield 3 colour shadow
#define COLOR4 ((u8)$2C8) // background colour shadow

// ── Page 2: Run/init vectors ────────────────────────────────────

#define RUNAD ((u16)$2E0)   // run address vector
#define INITAD ((u16)$2E2)  // init address vector
#define MEMTOP2 ((u16)$2E5) // display memory top
#define MEMLO ((u16)$2E7)   // OS memory low (start of free RAM)

// ── Page 2: Keyboard and misc ───────────────────────────────────

#define CHBAS ((u8)$2F4)  // character set base address (page)
#define ATACHR ((u8)$2FB) // ATASCII character for EOL
#define CH ((u8)$2FC)     // keyboard code (last key pressed)
#define FILDAT ((u8)$2FD) // colour fill data
#define DSPFLG ((u8)$2FE) // display control chars flag
#define SSFLAG ((u8)$2FF) // start/stop flag

// ── IOCB area ($340-$3BF) ───────────────────────────────────────

#define ICHID ((u8)$340)   // IOCB 0 handler ID (8 IOCBs x 16 bytes)
#define HATABS ((u16)$31A) // handler address table

// ── GTIA: hardware registers ($D000-$D01F) ──────────────────────
// Write registers:

#define HPOSP0 ((u8)$D000) // player 0 horizontal position
#define HPOSP1 ((u8)$D001) // player 1 horizontal position
#define HPOSP2 ((u8)$D002) // player 2 horizontal position
#define HPOSP3 ((u8)$D003) // player 3 horizontal position
#define HPOSM0 ((u8)$D004) // missile 0 horizontal position
#define HPOSM1 ((u8)$D005) // missile 1 horizontal position
#define HPOSM2 ((u8)$D006) // missile 2 horizontal position
#define HPOSM3 ((u8)$D007) // missile 3 horizontal position
#define SIZEP0 ((u8)$D008) // player 0 size
#define SIZEP1 ((u8)$D009) // player 1 size
#define SIZEP2 ((u8)$D00A) // player 2 size
#define SIZEP3 ((u8)$D00B) // player 3 size
#define SIZEM ((u8)$D00C)  // missile sizes (all 4)
#define GRAFP0 ((u8)$D00D) // player 0 graphics
#define GRAFP1 ((u8)$D00E) // player 1 graphics
#define GRAFP2 ((u8)$D00F) // player 2 graphics
#define GRAFP3 ((u8)$D010) // player 3 graphics
#define GRAFM ((u8)$D011)  // missile graphics
#define COLPM0 ((u8)$D012) // player/missile 0 colour
#define COLPM1 ((u8)$D013) // player/missile 1 colour
#define COLPM2 ((u8)$D014) // player/missile 2 colour
#define COLPM3 ((u8)$D015) // player/missile 3 colour
#define COLPF0 ((u8)$D016) // playfield 0 colour
#define COLPF1 ((u8)$D017) // playfield 1 colour
#define COLPF2 ((u8)$D018) // playfield 2 colour
#define COLPF3 ((u8)$D019) // playfield 3 colour
#define COLBK ((u8)$D01A)  // background colour
#define PRIOR ((u8)$D01B)  // priority select
#define VDELAY ((u8)$D01C) // vertical delay
#define GRACTL ((u8)$D01D) // graphics control
#define HITCLR ((u8)$D01E) // collision clear (strobe)
#define CONSOL ((u8)$D01F) // console switches

// GTIA read registers:
#define M0PF ((u8)$D000)  // missile 0-playfield collisions
#define M1PF ((u8)$D001)  // missile 1-playfield collisions
#define M2PF ((u8)$D002)  // missile 2-playfield collisions
#define M3PF ((u8)$D003)  // missile 3-playfield collisions
#define P0PF ((u8)$D004)  // player 0-playfield collisions
#define P1PF ((u8)$D005)  // player 1-playfield collisions
#define P2PF ((u8)$D006)  // player 2-playfield collisions
#define P3PF ((u8)$D007)  // player 3-playfield collisions
#define M0PL ((u8)$D008)  // missile 0-player collisions
#define M1PL ((u8)$D009)  // missile 1-player collisions
#define M2PL ((u8)$D00A)  // missile 2-player collisions
#define M3PL ((u8)$D00B)  // missile 3-player collisions
#define P0PL ((u8)$D00C)  // player 0-player collisions
#define P1PL ((u8)$D00D)  // player 1-player collisions
#define P2PL ((u8)$D00E)  // player 2-player collisions
#define P3PL ((u8)$D00F)  // player 3-player collisions
#define TRIG0 ((u8)$D010) // joystick trigger 0
#define TRIG1 ((u8)$D011) // joystick trigger 1
#define TRIG2 ((u8)$D012) // joystick trigger 2
#define TRIG3 ((u8)$D013) // joystick trigger 3
#define PAL ((u8)$D014)   // PAL/NTSC flag

// ── POKEY: hardware registers ($D200-$D20F) ─────────────────────
// Write registers:

#define AUDF1 ((u8)$D200)  // audio frequency 1
#define AUDC1 ((u8)$D201)  // audio control 1
#define AUDF2 ((u8)$D202)  // audio frequency 2
#define AUDC2 ((u8)$D203)  // audio control 2
#define AUDF3 ((u8)$D204)  // audio frequency 3
#define AUDC3 ((u8)$D205)  // audio control 3
#define AUDF4 ((u8)$D206)  // audio frequency 4
#define AUDC4 ((u8)$D207)  // audio control 4
#define AUDCTL ((u8)$D208) // audio control
#define STIMER ((u8)$D209) // start timers (strobe)
#define SKREST ((u8)$D20A) // reset serial status (strobe)
#define POTGO ((u8)$D20B)  // start pot scan (strobe)
#define SEROUT ((u8)$D20D) // serial output data
#define IRQEN ((u8)$D20E)  // IRQ interrupt enable
#define SKCTL ((u8)$D20F)  // serial port control

// POKEY read registers:
#define POT0 ((u8)$D200)   // paddle 0 value
#define POT1 ((u8)$D201)   // paddle 1 value
#define POT2 ((u8)$D202)   // paddle 2 value
#define POT3 ((u8)$D203)   // paddle 3 value
#define POT4 ((u8)$D204)   // paddle 4 value
#define POT5 ((u8)$D205)   // paddle 5 value
#define POT6 ((u8)$D206)   // paddle 6 value
#define POT7 ((u8)$D207)   // paddle 7 value
#define ALLPOT ((u8)$D208) // all pot scan status
#define KBCODE ((u8)$D209) // keyboard code
#define RANDOM ((u8)$D20A) // random number generator
#define SERIN ((u8)$D20D)  // serial input data
#define IRQST ((u8)$D20E)  // IRQ status
#define SKSTAT ((u8)$D20F) // serial port status

// ── PIA: hardware registers ($D300-$D303) ───────────────────────

#define PORTA ((u8)$D300) // port A (joystick 0+1)
#define PORTB ((u8)$D301) // port B (memory control on XL/XE)
#define PACTL ((u8)$D302) // port A control
#define PBCTL ((u8)$D303) // port B control

// ── ANTIC: hardware registers ($D400-$D40F) ─────────────────────
// Write registers:

#define DMACTL ((u8)$D400)  // DMA control
#define CHACTL ((u8)$D401)  // character control
#define DLISTL ((u16)$D402) // display list pointer (low)
#define DLISTH ((u8)$D403)  // display list pointer (high)
#define HSCROL ((u8)$D404)  // horizontal scroll
#define VSCROL ((u8)$D405)  // vertical scroll
#define PMBASE ((u8)$D407)  // player/missile base address (page)
#define CHBASE ((u8)$D409)  // character set base address (page)
#define WSYNC ((u8)$D40A)   // wait for horizontal sync (strobe)
#define NMIEN ((u8)$D40E)   // NMI interrupt enable
#define NMIRES ((u8)$D40F)  // NMI reset (strobe)

// ANTIC read registers:
#define VCOUNT ((u8)$D40B) // vertical line counter
#define PENH ((u8)$D40C)   // light pen horizontal
#define PENV ((u8)$D40D)   // light pen vertical
#define NMIST ((u8)$D40F)  // NMI status
