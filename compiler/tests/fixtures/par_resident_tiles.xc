// par_resident_tiles — a tiled block that reads a table WHOLE (its index is
// data, so it has no footprint), reads `idx` a slice per tile, and writes
// its own slice of `out`. On a GPU with its own memory the table is sent
// once and stays: a second run over the same table sends nothing
// (XC_PAR_REPORT shows "already on the GPU"), and `idx`, the same again,
// goes whole from the second run and stays too. After the program writes
// one table entry every device sends the table again — on two GPUs too,
// where one device's fresh upload must not make the other's old copy look
// current. The check recomputes every element on the CPU, so a stale copy
// shows as bad.
//
//xtc-na: xt6502, m68k, arm9, wasm32 — no page-aligned helper there
#import "Stdio.xc"
#import "Par.xc"

#define SIZE (1024 * 1024)
#define TABLE (1024 * 1024)

u32 check(u32* table, u32* idx, u32* out)
{
    u32 bad = (u32)0;
    for (u32 i in 0..SIZE)
    {
        u32 v = table[idx[i]];
        for (u32 k in 0..64)
            v = v * (u32)1664525 + (u32)1013904223 + i;
        if (out[i] != v)
            bad = bad + (u32)1;
    }
    return bad;
}

i32 main(void)
{
    simd: u32* table = new u32[TABLE];
    simd: u32* idx = new u32[SIZE];
    simd: u32* out = new u32[SIZE];
    for (u32 i in 0..TABLE)
        table[i] = i * (u32)2246822519;
    for (u32 i in 0..SIZE)
        idx[i] = (i * (u32)2654435761) % (u32)TABLE;
    for (u32 rep in 0..4)
    {
        // the last run's table has one entry changed (every item reads
        // index 0 on the way, so a stale copy is wrong everywhere)
        if (rep == (u32)3)
        {
            table[idx[0]] = (u32)12345;
            table[0] = (u32)777;
        }
        par lookup
        {
            for (u32 i in 0..SIZE)
            {
                u32 v = table[idx[i]] + table[0] - table[0];
                for (u32 k in 0..64)
                    v = v * (u32)1664525 + (u32)1013904223 + i;
                out[i] = v;
            }
        }
        Stdio.printf("run %u: %u bad\n", rep, check(table, idx, out));
    }
    return 0;
}
