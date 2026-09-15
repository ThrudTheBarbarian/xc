// banked_arg_spilled_arr.xc — reading from a spilled stack array
// of `banked:T@` must return all 3 bytes of each element.
//
// The ZP-resident array path (arrayBaseSubscriptReadOrNo) grew
// elemWidth == 3 support in earlier commits; the SPILL path
// (emitSubscriptExpr CASE A) was separately gated on
// `elemWidth == 2 || elemWidth == 4` and fell through to the
// u8 legacy path for width 3 — which emits a single `LDA
// spill+i,<scale>` and leaves X/Y holding caller-save garbage.
// `peek(arr[i])` then dispatched with a pointer whose bank
// byte and high byte were both wrong.
//
// Under heavy ZP pressure (128 u8 locals declared ahead of the
// array) the stack array lands in the data section and hits
// this path.
//
// T1-T2  Const-index peek on a spilled banked:Leaf@ array.
// T3-T4  Dynamic-index peek (i*3 scaling).

#import "Stdio.xc"
#import "Assert.xc"

class Leaf
{
    u8 id;
    void dealloc(void) { }
}

u8 peek(banked:Leaf* p)
{
    return p.id;
}

void main(void)
{
    Assert.reset();

    // ZP pressure — force the array below into the data section.
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

    banked:Leaf* arr[2];
    arr[0] = new Leaf();
    arr[0].id = 77;
    arr[1] = new Leaf();
    arr[1].id = 88;

    // Const-index
    Assert.isEqual(peek(arr[0]), 77);                  // T1
    Assert.isEqual(peek(arr[1]), 88);                  // T2

    // Dynamic-index — exercises the i*3 + 16-bit base stage.
    u8 i;
    i = 0;
    Assert.isEqual(peek(arr[i]), 77);                  // T3
    i = 1;
    Assert.isEqual(peek(arr[i]), 88);                  // T4

    Assert.summary();
    return;
}
