// banked_arg_spilled_arr_method.xc — passing spilled `banked:T@`
// array elements into methods and retaining through the full
// ARC lifecycle.
//
// Two bugs lived on this path:
//
//  (1) emitMethodCallExpr's receiver-class lookup gated on
//      `_globalAddresses[receiverName]`. Spilled locals (ZP-
//      exhausted on xe-heap, or swap-region on xt-heap → actually
//      also spilled in this specific shape) aren't in that map,
//      so `s.consume(...)` where `s` is a spilled `Store@`
//      silently fell into the static-call branch and synthesised
//      the broken label `_cls_s_consume`.
//
//  (2) emitPushArgWidth covered widths 1 and 2 only. Banked-
//      pointer args (width 3) hit the width-2 branch, which
//      starts with `TAY` — clobbering Y (bank) and pushing only
//      hi / lo. The callee then PLA'd three bytes but only two
//      were on the stack, corrupting the hw-stack return frame
//      and hanging the simulator.
//
// T1  `s.consume(arr[0])` + `s.consume(arr[1])`: method fires
//     twice, each arr element still alive after the calls.
// T2  Scope-exit releases both arr elements once each.

#import "Stdio.xc"
#import "Assert.xc"

u16 leafDealloc;
u16 storeCount;

class Leaf
{
    u8 id;
    void dealloc(void) { leafDealloc = leafDealloc + 1; }
}

class Store
{
    u8 unused;
    void dealloc(void) { }
    void consume(banked:Leaf* p)
    {
        u8 tmp;
        tmp = p.id;
        storeCount = storeCount + 1;
    }
}

void run(void)
{
    // ZP pressure — pushes arr and s into the data-section spill
    // path on xe-heap and into the bank-swap-region on xt-heap.
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
    arr[0].id = 10;
    arr[1] = new Leaf();
    arr[1].id = 20;

    Store* s = new Store();
    s.consume(arr[0]);
    s.consume(arr[1]);
    return;
}

void main(void)
{
    Assert.reset();
    leafDealloc = 0;
    storeCount = 0;
    run();
    Assert.isEqual(storeCount, 2);             // T1: consume fired twice
    Assert.isEqual(leafDealloc, 2);            // T2: both arr elements deallocated
    Assert.summary();
    return;
}
