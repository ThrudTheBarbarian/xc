// Arm64AsmDefs.xc — the constants of Arm64Asm.xc.xc, apart from its code so a file
// compiled against its interface (the split build) can still see them.
#define FIXUP_BRANCH26      0
#define FIXUP_PAGE21        1
#define FIXUP_PAGEOFF12     2
#define FIXUP_POINTER64     3
#define FIXUP_GOTPAGE21     4
#define FIXUP_GOTPAGEOFF12  5
#define FIXUP_PREL32        6   // a 32-bit `target - here` word in DATA (an ELF jump table); the archive reader alone makes one
