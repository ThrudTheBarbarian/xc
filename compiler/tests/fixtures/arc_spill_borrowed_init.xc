// arc_spill_borrowed_init.xc — spilled strong-pointer local
// with a borrowed initialiser used to miss its `_obj_retain`.
//
// `Foo@ a = b;` where `a` lands in the data section (ZP
// exhausted) ought to retain so `a`'s scope-exit decref
// balances against the assignment's +0 borrow. The ZP-resident
// branch emits the retain; the spill branch silently omitted
// it, so b's refcount was decremented without a matching
// increment — and on a long-lived heap reference the object
// deallocates inside the spill-site function, leaving the
// caller's pointer dangling.
//
// T1  After `churn(owner)` returns, `owner`'s object must still
//     be alive (dealloc count == 0). With the bug, the spilled
//     `a` in churn decrements owner's refcount to zero and
//     dealloc fires early.
// T2  Release `owner` — dealloc count must be exactly 1.
//
// We force the spill by declaring 128 u8 locals in churn ahead
// of `a`, exhausting ZP. All ARC configurations.

#import "Stdio.xc"
#import "Assert.xc"

u16 leafDealloc;

class Leaf
{
    u8 id;
    void dealloc(void) { leafDealloc = leafDealloc + 1; }
}

void churn(Leaf* src)
{
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

    Leaf* a = src;
    return;
}

void main(void)
{
    Assert.reset();
    leafDealloc = 0;

    Leaf* owner = new Leaf();
    churn(owner);
    Assert.isEqual(leafDealloc, 0);            // T1: owner still alive

    owner = (Leaf*)0;
    Assert.isEqual(leafDealloc, 1);            // T2: exactly one dealloc

    Assert.summary();
    return;
}
