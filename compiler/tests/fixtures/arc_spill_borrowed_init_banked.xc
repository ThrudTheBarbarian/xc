// arc_spill_borrowed_init_banked.xc — borrowed-init retain for
// an explicit `banked:T@` (3-byte) strong pointer that lands in
// the data section.
//
// The size <= 2 spill path grew a borrowed-init retain + proper
// scope-exit balance in an earlier commit. The 3-byte banked
// placement had two gaps on the same path:
//
//   1. The generic-expression spill store wrote A / X only,
//      dropping the bank byte from Y into a silently-zero slot+2.
//      emitExprToA on a banked:T@ source yields A=lo / X=hi /
//      Y=bank; the spill init has to STY slot+2 to keep the
//      bank live.
//
//   2. The borrowed-init retain block read slot+0 / slot+1 into
//      A / X and loaded #heap_bank_first into Y — wrong for a
//      3-byte banked slot, which needs the per-instance bank
//      byte from slot+2 into Y before _obj_retain.
//
// Either gap corrupts the source's refcount (source's refcount
// decrements on scope-exit without a matching +1 from the
// borrowed-init retain, so the object deallocs inside the
// spill-site function and the caller's pointer dangles).
//
// T1  makeAndChurn() allocates a banked:Leaf@ owner,
//     forwards it to churn(), which binds `banked:Leaf@ a = src;`
//     under ZP pressure so `a` lands in the data section.
//     owner survives churn's scope-exit and deallocs exactly
//     once when makeAndChurn() returns.

#import "Stdio.xc"
#import "Assert.xc"

u16 leafDealloc;

class Leaf
{
    u8 id;
    void dealloc(void) { leafDealloc = leafDealloc + 1; }
}

void churn(banked:Leaf* src)
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

    // 3-byte banked pointer with a borrowed initialiser.
    // Lands in the data section via _spill_a.
    banked:Leaf* a = src;
    return;
}

void makeAndChurn(void)
{
    banked:Leaf* owner = new Leaf();
    churn(owner);
    return;  // owner scope-exits — one dealloc expected.
}

void main(void)
{
    Assert.reset();
    leafDealloc = 0;
    makeAndChurn();
    Assert.isEqual(leafDealloc, 1);
    Assert.summary();
    return;
}
