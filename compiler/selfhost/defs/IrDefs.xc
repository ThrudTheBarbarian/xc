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
// Opcode properties, one bit each in IROp's table. Each set is the one the
// optimiser's own predicates used; the comments name the opcodes.
#define OPF_PURE $0001        // a value computation that cannot trap: speculatable's list
#define OPF_TRAPS $0002       // a value computation that may trap: the divides and remainders, and FDiv
#define OPF_MEM $0004         // takes and returns a memory token: touchesMemory's list
#define OPF_WRITES $0008      // may write memory: every store, call and dispatch, Invoke, the ARC and weak ops, Asm, VaStart, VaArg
#define OPF_CALL $0010        // Call, CallCloaked, CallBanked, CallIndirect, CallBankedIndirect
#define OPF_CALL_DIRECT $0020 // a call to a named function: Call, CallBanked, CallCloaked
#define OPF_DISPATCH $0040    // a method call through a table: VTblDispatch, ProtoDispatch
#define OPF_CLOBBERS $0080    // may clobber the caller-saved registers: the back ends' homing list
#define OPF_TERM $0100        // ends a block: the branches, Return, Unreachable, Invoke and Resume
// IRFunc.parKernel(): what made the function a par block's kernel, printed as
// the function's `par:` line. Set where the kernel is made, never read from
// its name: a class of the program's own may be called ParImpl.
#define PARK_NONE $00
#define PARK_BLOCK $01
#define PARK_OUTLINED $02
// IRRuntime.role(): what a runtime check symbol (Checked.xc, CheckedVtbl.xc)
// is to the passes.
#define RT_NONE $00
#define RT_CHECK $01
#define RT_LIMIT $02
#define RT_TRAP $03
#define RT_TRAP_RETURNS $04
#define RT_HELPER $05
#define RT_DATA $06

// A byte-list zero tail of at least this many fixed-width scalar elements is
// one MemSet of its bytes, not a store apiece (#617). Both compilers.
#define ZERO_RUN_MEMSET 16

// An atomic's memory order (LLVM's, weakest first): monotonic (C's relaxed),
// acquire, release, acq_rel, seq_cst. The kinds of AtomicRMW.
#define ATOMIC_RELAXED 0
#define ATOMIC_ACQUIRE 1
#define ATOMIC_RELEASE 2
#define ATOMIC_ACQREL 3
#define ATOMIC_SEQCST 4
#define ATOMIC_RMW_XCHG 0
#define ATOMIC_RMW_ADD 1
#define ATOMIC_RMW_SUB 2
#define ATOMIC_RMW_AND 3
#define ATOMIC_RMW_OR 4
#define ATOMIC_RMW_XOR 5
