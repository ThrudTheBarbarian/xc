// IrDefs.xc — the constants of Ir.xc.xc, apart from its code so a file
// compiled against its interface (the split build) can still see them.
#define OPK_USE $00
#define OPK_IMMI $01
#define OPK_IMMF $02
#define OPK_SYM $03
#define OPK_BLOCK $04
#define OPK_CPOOL $05
#define SYM_FUNCTION $00
#define SYM_DATAGLOBAL $01
#define SYM_STRINGLIT $02
#define SYM_VTABLE $03
#define SYM_RUNTIME $04
// IRFunc.parKernel(): what made the function a par block's kernel, printed as
// the function's `par:` line. Set where the kernel is made, never read from
// its name: a class of the program's own may be called ParImpl.
#define PARK_NONE $00
#define PARK_BLOCK $01
#define PARK_OUTLINED $02
