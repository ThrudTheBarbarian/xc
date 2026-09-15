// spill_dyn_index.xc — dynamic-index reads on spilled arrays
// of widths 2 and 4 must scale the index and read all bytes.
// Before the fix, emitSubscriptExpr's CASE A (spilled array,
// absolute addressing) had no dynamic-index handler for widths
// 2 or 4; they fell through to the u8 legacy path which emits
// a single LDA with no scaling, silently returning one byte of
// garbage instead of the indexed element.
//
// Pre-ARC / placement-agnostic. Runs on every flat and banked
// target.
//
// T1-T2  u16 read at runtime index.
// T3-T4  u32 read at runtime index, checked via two u16 halves.

#import "Stdio.xc"
#import "Assert.xc"

void main(void)
{
    u16 arr16[3];
    u32 arr32[3];
    arr16[0] = $1111; arr16[1] = $2222; arr16[2] = $3333;
    arr32[0] = $11112222; arr32[1] = $33334444; arr32[2] = $55556666;

    // Force the arrays to spill by declaring them in a block
    // where heavy ZP pressure pushes them out. The arrays above
    // are compile-time known so we can assert on them; the ones
    // below are the spilled ones we actually test.
    Assert.reset();

    // ZP pressure — keep arr16 / arr32 in ZP so the init works,
    // then shift to spilled copies for the dynamic-index test.
    u8 v000; u8 v001; u8 v002; u8 v003; u8 v004; u8 v005; u8 v006; u8 v007;
    u8 v008; u8 v009; u8 v010; u8 v011; u8 v012; u8 v013; u8 v014; u8 v015;
    u8 v016; u8 v017; u8 v018; u8 v019; u8 v020; u8 v021; u8 v022; u8 v023;
    u8 v024; u8 v025; u8 v026; u8 v027; u8 v028; u8 v029; u8 v030; u8 v031;
    u8 v032; u8 v033; u8 v034; u8 v035; u8 v036; u8 v037; u8 v038; u8 v039;
    u8 v040; u8 v041; u8 v042; u8 v043; u8 v044; u8 v045; u8 v046; u8 v047;
    u8 v048; u8 v049; u8 v050; u8 v051; u8 v052; u8 v053; u8 v054; u8 v055;
    u8 v056; u8 v057; u8 v058; u8 v059; u8 v060; u8 v061; u8 v062; u8 v063;
    u8 v064; u8 v065; u8 v066; u8 v067; u8 v068; u8 v069; u8 v070; u8 v071;
    u8 v072; u8 v073; u8 v074; u8 v075; u8 v076; u8 v077; u8 v078; u8 v079;
    u8 v080; u8 v081; u8 v082; u8 v083; u8 v084; u8 v085; u8 v086; u8 v087;
    u8 v088; u8 v089; u8 v090; u8 v091; u8 v092; u8 v093; u8 v094; u8 v095;
    u8 v096; u8 v097; u8 v098; u8 v099; u8 v100; u8 v101; u8 v102; u8 v103;
    u8 v104; u8 v105; u8 v106; u8 v107; u8 v108; u8 v109; u8 v110; u8 v111;
    u8 v112; u8 v113; u8 v114; u8 v115; u8 v116; u8 v117; u8 v118; u8 v119;
    u8 v120; u8 v121; u8 v122; u8 v123; u8 v124; u8 v125; u8 v126; u8 v127;
    v000 = 1; v127 = 2;

    u16 sp16[3];
    u32 sp32[3];
    sp16[0] = $1111; sp16[1] = $2222; sp16[2] = $3333;
    sp32[0] = $11112222; sp32[1] = $33334444; sp32[2] = $55556666;

    u8 i;
    u16 r16;
    u32 r32;
    u16 r32lo;
    u16 r32hi;

    i = 0;
    r16 = sp16[i];           Assert.isEqual(r16, $1111);      // T1
    r32 = sp32[i];
    r32lo = (u16)(r32 & $ffff);
    r32hi = (u16)(r32 >> 16);
    Assert.isEqual(r32lo, $2222);                             // T2a
    Assert.isEqual(r32hi, $1111);                             // T2b

    i = 2;
    r16 = sp16[i];           Assert.isEqual(r16, $3333);      // T3
    r32 = sp32[i];
    r32lo = (u16)(r32 & $ffff);
    r32hi = (u16)(r32 >> 16);
    Assert.isEqual(r32lo, $6666);                             // T4a
    Assert.isEqual(r32hi, $5555);                             // T4b

    Assert.summary();
    return;
}
