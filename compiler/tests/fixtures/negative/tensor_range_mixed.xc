// Only a tensor mixes ranges and indices in one subscript.
// xtc: error "'Grid' takes a range index alone in the brackets, as in s[lo..hi]; only a tensor mixes ranges and indices"
#import "Stdio.xc"
class Grid
{
    i32 cells[16];
    i32 at(u64 i, u64 j) :operator(self[i, j]) { return cells[i * 4 + j]; }
}
i32 main(void)
{
    Grid* g = new Grid();
    return g[1, 0..2];
}
