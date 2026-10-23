// CoffObjectDefs.xc — the constants of CoffObject.xc.xc, apart from its code so a file
// compiled against its interface (the split build) can still see them.
#define COFF_MACHINE_AMD64 $8664
#define COFF_SCN_CODE $00000020
#define COFF_SCN_INIT_DATA $00000040
#define COFF_SCN_UNINIT_DATA $00000080
#define COFF_SCN_DISCARDABLE $02000000
#define COFF_SECT_HDR_SIZE 40
#define COFF_SYM_SZ 18
#define COFF_RELOC_SZ 10
#define COFF_REL_ADDR64 $01
#define COFF_REL_REL32 $04
