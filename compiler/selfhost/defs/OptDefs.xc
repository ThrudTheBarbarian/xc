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
