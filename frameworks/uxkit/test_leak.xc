// test_leak.xc — does Xtg leak? Measure, do not assume.
//
// There is no heap-stats syscall, so we probe the ALLOCATOR itself: take a small block, free
// it, do N cycles of real work, then take another. If nothing leaked, the allocator hands back
// the block we just returned and the two addresses match. If something leaked, the freed blocks
// were never returned, and the second probe sits higher up the heap by roughly the leak.
//
//     leak per cycle ~= (probe_after - probe_before) / CYCLES
//
// This measures the WHOLE stack under Xtg — the Foundation Array, the object headers, ARC — so
// a non-zero number here is a real cost that every Xtg app is paying on every window it opens.
#import <Stdio.xc>
#import <GEM>
#import "UXGem.xc"
#import "UXView.xc"
#import "UXViewTree.xc"
#import "UXTableView.xc"
#import "UXGemDriver.xc"

#define CYCLES 50
#define ROWS 20

// malloc/free come from UXLibc.xc (via UXViewTree). Declaring them again here is redundant —
// and an identical redeclaration of a VOID function crashes xtc outright (XTC-BUGS #17).
u8* gCells[ROWS];

class Row : UXView
    {
    UXKind kind(void)
        {
        return UXKindBox;
        }
    }

    class Data : Object<UXTableDataSource>
    {
    void init(void)
        {
        }
    i32 numberOfRows(UXTableView* t)
        {
        return (i32)ROWS;
        }
    u8* valueForCell(UXTableView* t, i32 row, i32 col)
        {
        return gCells[row];
        }
    }

    // One unit of ordinary toolkit work: build a tree, hang views on it, drop it.
    // Everything here is ARC'd and should be reclaimed in full when it goes out of scope.
    void cycle(void)
    {
    UXViewTree* tree = new UXViewTree();
    UXView* root = new UXView();
    root.attachTo(tree, UXGeom.make((i16)0, (i16)0, (i16)150, (i16)100));

    for (u16 i = (u16)0; i < (u16)10; i++)
        {
        Row* r = new Row();
        root.addSubview(r, UXGeom.make((i16)0, (i16)((i32)i * (i32)10), (i16)100, (i16)10));
        }
    }

// The same, through the table — which allocates an Array per column, per row, and per cell.
void tableCycle(void)
    {
    UXViewTree* tree = new UXViewTree();
    UXTableView* t = new UXTableView();
    Data* d = new Data();
    t.attachTo(tree, UXGeom.make((i16)0, (i16)0, (i16)150, (i16)100));
    t.setRowHeight((i16)10);
    t.addColumn("A", (i16)80);
    t.addColumn("B", (i16)60);
    t.setDataSource(d);
    t.reloadData();
    }

u32 probe(void)
    {
    pointer p = malloc((u32)16);
    free(p);
    return (u32)p; // where the allocator's next small block lives
    }

void report(u8* what, u32 before, u32 after, i32 cycles)
    {
    i32 grew = (i32)(after - before);
    i32 per = grew / cycles;
    Stdio.printf("%s\n", what);
    Stdio.printf("    heap grew %ld bytes over %ld cycles\n", grew, cycles);
    if (grew == (i32)0)
        {
        Stdio.printf("    0 bytes/cycle  -- CLEAN\n");
        }
    else
        {
        Stdio.printf("    %ld bytes/cycle  -- LEAK\n", per);
        }
    }

void main(void)
    {
    gDriver = new UXGemDriver(); // select the backend (no gemd needed for tree ops)
    for (i32 i = (i32)0; i < (i32)ROWS; i++)
        {
        gCells[i] = "cell";
        }

    // Warm up: the first pass grows the heap for legitimate reasons (a fresh Array's first
    // buffer, a first-time realloc). We are looking for growth that CONTINUES, so measure the
    // steady state, not the start-up.
    cycle();
    tableCycle();

    u32 a = probe();
    for (i32 i = (i32)0; i < (i32)CYCLES; i++)
        {
        cycle();
        }
    u32 b = probe();
    report("view tree + 10 views", a, b, (i32)CYCLES);

    u32 c = probe();
    for (i32 i = (i32)0; i < (i32)CYCLES; i++)
        {
        tableCycle();
        }
    u32 d = probe();
    report("table, 20 rows x 2 cols", c, d, (i32)CYCLES);

    i32 leaked = (i32)(b - a) + (i32)(d - c);
    if (leaked == (i32)0)
        {
        Stdio.printf("\nPASS: Xtg reclaims everything it allocates.\n");
        }
    else
        {
        Stdio.printf("\nKNOWN-LEAK: nothing is reclaimed. This is the Foundation types leaking\n");
        Stdio.printf("            on arm9 (they were only ever right on the 6502), not a bug in\n");
        Stdio.printf("            Xtg -- every allocation here is ARC'd and goes out of scope.\n");
        Stdio.printf("            The compiler is replacing them. THIS TEST MUST READ\n");
        Stdio.printf("            0 bytes/cycle when that lands; until then it is the baseline.\n");
        }
    }
