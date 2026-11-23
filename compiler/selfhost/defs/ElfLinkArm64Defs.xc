// ElfLinkArm64Defs.xc — the constants of ElfLinkArm64.xc.xc, apart from its code so a file
// compiled against its interface (the split build) can still see them.
#define RA64_ABS64              257
#define RA64_PREL64             260
#define RA64_PREL32             261
#define RA64_ADR_PREL_PG_HI21   275
#define RA64_ADD_ABS_LO12_NC    277
#define RA64_LDST8_ABS_LO12_NC  278
#define RA64_JUMP26             282
#define RA64_CALL26             283
#define RA64_LDST16_ABS_LO12_NC 284
#define RA64_LDST32_ABS_LO12_NC 285
#define RA64_LDST64_ABS_LO12_NC 286
#define RA64_LDST128_ABS_LO12_NC 299
#define RA64_ADR_GOT_PAGE       311
#define RA64_LD64_GOT_LO12_NC   312
// Thread-local storage: initial-exec (GOT slot) and local-exec forms.
#define RA64_TLSIE_ADR_GOTTPREL_PAGE21   541
#define RA64_TLSIE_LD64_GOTTPREL_LO12_NC 542
#define RA64_TLSLE_MOVW_TPREL_G2         544
#define RA64_TLSLE_MOVW_TPREL_G1         545
#define RA64_TLSLE_MOVW_TPREL_G1_NC      546
#define RA64_TLSLE_MOVW_TPREL_G0         547
#define RA64_TLSLE_MOVW_TPREL_G0_NC      548
#define RA64_TLSLE_ADD_TPREL_HI12        549
#define RA64_TLSLE_ADD_TPREL_LO12        550
#define RA64_TLSLE_ADD_TPREL_LO12_NC     551
#define RA64_TLSLE_LDST8_TPREL_LO12      552
#define RA64_TLSLE_LDST128_TPREL_LO12_NC 571
