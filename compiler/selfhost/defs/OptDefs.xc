// OptDefs.xc — the constants of Opt.xc.xc, apart from its code so a file
// compiled against its interface (the split build) can still see them.
#define LRC_LEAK $FFFFFFFF
#define VEC_SPLAT_HOIST_MAX 8
#define VEC_SPLAT_BIG_BODY 96
#define GPU_GLOBAL_MIN 65536
#define GPU_GLOBAL_PAGE 16384

// OptDevirt: at most this many candidate classes at a site, each method at
// most this many instructions.
#define DV_MAX 4
#define DV_BODY 24
#define DV_LOOP 64
// The fewest items a loop of constant trip needs to be outlined as a par block.
#define PP_MIN_TRIP 256
// The kinds of a bound term of the overlap guard (#219): a constant, the
// iteration (i + c), or a value from outside the loop (+ c), zero- or
// sign-extended to 64 bits.
#define PP_BND_CONST 0
#define PP_BND_IV 1
#define PP_BND_VALZ 2
#define PP_BND_VALS 3
// gpuLength's answer for a read-only capture the call site's overlap guard
// compares by range with every stored array, where its heap block's size is
// unknown: the runtime's bufferOverlap (ParDevice.xc) takes it as apart.
#define PAR_LEN_CHECKED_AT_CALL (0 - 2)
// The most Selects selectBranch turns into branches in one function.
#define SB_MAX 64
