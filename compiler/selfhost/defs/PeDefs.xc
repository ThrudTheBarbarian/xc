// PeDefs.xc — the constants of Pe.xc.xc, apart from its code so a file
// compiled against its interface (the split build) can still see them.
#define PE_FILE_ALIGN $200
#define PE_SECT_ALIGN $1000
#define PE_OPT_HDR_SIZE 240
#define PE_SECT_HDR_SIZE 40
#define PE_THUNK_SZ 6
#define PE_BASE_LO $40000000
#define PE_DLL_BASE_LO $80000000
#define PE_BASE_HI 1
