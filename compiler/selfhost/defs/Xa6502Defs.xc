// Xa6502Defs.xc — the constants of Xa6502.xc.xc, apart from its code so a file
// compiled against its interface (the split build) can still see them.
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
