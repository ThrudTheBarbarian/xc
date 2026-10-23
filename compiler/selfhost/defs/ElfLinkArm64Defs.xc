// ElfLinkArm64Defs.xc — the constants of ElfLinkArm64.xc.xc, apart from its code so a file
// compiled against its interface (the split build) can still see them.
#define RA64_ABS64              257
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
