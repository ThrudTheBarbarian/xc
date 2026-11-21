// NodeDefs.xc — the constants of Node.xc.xc, apart from its code so a file
// compiled against its interface (the split build) can still see them.
#define NF_STATIC $0001
#define NF_VARARGS $0002
#define NF_THROWS $0004
#define NF_OPTIONAL $0008
#define NF_FINAL $0010
#define NF_GLOBAL $0020
#define NF_EXTERN $0040
#define NF_VOLATILE $0080
#define NF_REGISTER $0100
#define NF_ARROW $0200
#define NF_INCLUSIVE $0400
#define NF_FAILABLE $0800
#define NF_DEFAULT $1000
#define NF_RANGE $2000
#define NF_RANGE_HI $20000
#define NF_DECLLIST $4000
#define NF_BANKED $8000
#define NF_CLOAKED $10000
#define NF_MAINRAM $0400
#define NF_IRQ $40000
#define NF_VBI $80000
#define NF_XTCSTACK $80000000
#define NF_HWSTACK $20000
#define NF_CABI $200000
#define NF_VAFWD $400000
#define NF_PACKED $800000
#define NF_FIELDCALL $1000000
#define NF_SYNTH $100000
#define NF_EXTERNAL $2000000
#define NF_CHAINM $4000000
#define NF_UNROLL $08000000
#define NF_GOAL_SPEED $40000
#define NF_GOAL_ACCURACY $80000
#define NF_MODINIT $40000000
#define NF_OUTLET $10000000
#define NF_ACTION $20000000
#define NF_EXPORTED $8000000
// On a class declaration only: the class the parser made of a par block. Its
// bit is NF_IRQ's and NF_GOAL_SPEED's, which are on functions and loops.
#define NF_PARBLOCK $40000

// Source facts (Node.src()): what the tokens said that the tree no longer
// shows, kept in a word of their own so no reader of the flags above sees
// them. --par-style=auto's recogniser reads them, so its decisions on the
// tree are those the tokens gave (#338). The dump does not print them.
// An expression written in parentheses.
#define SRC_PAREN $0001
// An integer literal spelled as its decimal value (`1`, not `0x1`, `01`, `$1`).
#define SRC_PLAIN $0002
// A `for` written as a range (`for (T i in a..b)`), desugared to C-style.
#define SRC_RANGE $0004
// A `for` annotated `: serial`.
#define SRC_SERIAL $0008
// A `for` with a `: goal(…)` of its own (its goal flags also carry the
// enclosing goal).
#define SRC_GOAL $0010
// A range `for` whose `step` is not followed by an integer literal, or is
// followed by the literal `0`.
#define SRC_STEPBAD $0020
// A range `for` whose bounds are two integer literals that descend, read as
// --par-style=auto reads their spelling.
#define SRC_DESC $0040
// A call whose callee name or member was written in parentheses (`(f)(x)`).
#define SRC_PARENCALLEE $0080
// A range `for` in the form a :scan takes: written with a type, without a
// `step` or an annotation, its body braced.
#define SRC_SCANFORM $0100
// A node the parser made rather than read, which the par frame walk passes
// over: a name it used no binding for (a type keyword as a receiver, `par.x`
// in a grid), or a statement it added beside a declaration.
#define SRC_SYNTH $0400
// A call `b(...)` the parser made into `b.invoke(...)`: through a block
// binding, or a named literal calling itself.
#define SRC_CALLED $0800
// A loop with an annotation the parser does not know (it warns and drops it).
// It stays: --par-style=auto reads it, and an outer loop holding an inner loop
// with an unknown annotation stays serial. Without it that outer loop would be
// lifted, which is a widening of auto, deferred until its safety fixes settle
// (#523).
#define SRC_ANNOT $1000
