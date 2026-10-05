// test_rkmodel.xc — the resource model, and the flatten() that rebuilds the
// classic linked layout.
//
// flatten is the one place with real logic: the editor works on a NESTED tree,
// the file wants a pre-order array with next/head/tail links, and rebuilding
// it at write time is what stops the two representations ever disagreeing.
// The links are fiddly in the classic way — a last child's `next` points back
// at its PARENT, not forward — so they are worth pinning down.
#import <Stdio.xc>
#import "UXRscModel.xc"

i32 gFails;
void check(u8* what, i32 got, i32 want)
    {
    if (got == want)
        {
        Stdio.printf("  ok   %s = %d\n", what, (i16)got);
        }
    else
        {
        Stdio.printf("  FAIL %s = %d (want %d)\n", what, (i16)got, (i16)want);
        gFails = gFails + (i32)1;
        }
    }
void checkTrue(u8* what, bool got)
    {
    if (got)
        {
        Stdio.printf("  ok   %s\n", what);
        }
    else
        {
        Stdio.printf("  FAIL %s\n", what);
        gFails = gFails + (i32)1;
        }
    }

void main(void)
    {
    gFails = (i32)0;

    // ---- the colour word round-trips through the packed 16 bits ------------
    UXRscColor* c = new UXRscColor();
    c.border = (i32)3;
    c.text = (i32)5;
    c.replace = true;
    c.pattern = (i32)6;
    c.inside = (i32)9;
    UXRscColor* back = UXRscColor.unpack(c.pack());
    check("colour border survives pack", back.border, (i32)3);
    check("colour text survives pack", back.text, (i32)5);
    checkTrue("colour replace survives pack", back.replace);
    check("colour pattern survives pack", back.pattern, (i32)6);
    check("colour inside survives pack", back.inside, (i32)9);

    // ---- payload seeding follows the type ---------------------------------
    UXRscObject* field = UXRscObject.make((i32)UXR_T_FIELD, (i32)0, (i32)0, (i32)100, (i32)20);
    checkTrue("a field gets a TEDINFO", field.ted != (UXRscTedinfo*)0);
    checkTrue("a field has no box", field.box == (UXRscBox*)0);
    UXRscObject* boxo = UXRscObject.make((i32)UXR_T_BOX, (i32)0, (i32)0, (i32)10, (i32)10);
    checkTrue("a box gets a box payload", boxo.box != (UXRscBox*)0);
    UXRscObject* icon = UXRscObject.make((i32)UXR_T_CICON, (i32)0, (i32)0, (i32)32, (i32)32);
    checkTrue("a cicon gets an icon payload", icon.icon != (UXRscIcon*)0);

    // ---- a small tree:  root -> [a -> [a1], b] ----------------------------
    UXRscTree* t = new UXRscTree();
    t.name = (u8*)"TEST";
    UXRscObject* root = UXRscObject.make((i32)UXR_T_BOX, (i32)0, (i32)0, (i32)200, (i32)100);
    UXRscObject* a = UXRscObject.make((i32)UXR_T_IBOX, (i32)10, (i32)10, (i32)80, (i32)60);
    UXRscObject* a1 = UXRscObject.make((i32)UXR_T_BUTTON, (i32)5, (i32)5, (i32)40, (i32)20);
    UXRscObject* b = UXRscObject.make((i32)UXR_T_STRING, (i32)100, (i32)10, (i32)60, (i32)20);
    root.addChild(a);
    a.addChild(a1);
    root.addChild(b);
    t.root = root;

    check("tree holds 4 objects", (i32)t.allObjects().count(), (i32)4);
    checkTrue("parentOf finds the direct parent", t.parentOf(a1) == a);
    checkTrue("parentOf the root is nothing", t.parentOf(root) == (UXRscObject*)0);

    // absolute origin accumulates through the nesting: 10+5 across, 10+5 down
    i32 ax = (i32)0;
    i32 ay = (i32)0;
    checkTrue("absolute origin resolves", t.absoluteOriginOf(a1, &ax, &ay));
    check("absolute x", ax, (i32)15);
    check("absolute y", ay, (i32)15);

    // ---- flatten: pre-order, with the classic links -----------------------
    UXRscDoc* r = new UXRscDoc();
    Array<UXRscFlatNode>* flat = r.flatten(t);
    check("flattened count", (i32)flat.count(), (i32)4);

    UXRscFlatNode* f0 = (UXRscFlatNode* ?)flat.get((u16)0);   // root
    UXRscFlatNode* f1 = (UXRscFlatNode* ?)flat.get((u16)1);   // a
    UXRscFlatNode* f2 = (UXRscFlatNode* ?)flat.get((u16)2);   // a1
    UXRscFlatNode* f3 = (UXRscFlatNode* ?)flat.get((u16)3);   // b

    checkTrue("pre-order puts root first", f0.obj == root);
    checkTrue("then a", f1.obj == a);
    checkTrue("then a's child", f2.obj == a1);
    checkTrue("then b", f3.obj == b);

    check("root.head is a", f0.head, (i32)1);
    check("root.tail is b", f0.tail, (i32)3);
    check("a.head is a1", f1.head, (i32)2);
    check("a.tail is a1", f1.tail, (i32)2);
    check("a1 has no children", f2.head, (i32)-1);

    // the fiddly part: a last child's next points BACK at its parent
    check("a.next is its sibling b", f1.next, (i32)3);
    check("a1 (only child) points back at a", f2.next, (i32)1);
    check("b (last child) points back at root", f3.next, (i32)0);

    // and the final object carries LASTOB
    checkTrue("the last object is flagged LASTOB",
              (f3.obj.flags & (i32)UXR_F_LASTOB) != (i32)0);
    checkTrue("an earlier object is not", (f1.obj.flags & (i32)UXR_F_LASTOB) == (i32)0);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: the resource model flattens to the classic linked layout\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
