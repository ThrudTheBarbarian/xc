// WasmDefs.xc — the constants of Wasm.xc.xc, apart from its code so a file
// compiled against its interface (the split build) can still see them.
#define WIMM_NONE 0
#define WIMM_I32 1
#define WIMM_I64 2
#define WIMM_F32 3
#define WIMM_F64 4
#define WIMM_LABEL 5
#define WIMM_LOCAL 6
#define WIMM_GLOBAL 7
#define WIMM_CALL 8
#define WIMM_BRTABLE 9
#define WIMM_MEM 10
#define WIMM_MEMPAIR 11
#define WIMM_LANE 12
#define WIMM_LANES16 13
