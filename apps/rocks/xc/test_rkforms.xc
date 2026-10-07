// test_rkforms.xc — layout variants: a form, its phone layouts, logical identity, and the UXNB v2
// chunk that carries them (docs/UXNB-V2.md sections 1-3, 7 and 10).
//
// The written file is checked through UXKIT'S OWN LOADER (UXRscV2), not Rocks' reader: the chunk
// is an interchange format, and what matters is that the thing apps load with picks the right
// tree and binds the right control.  Then Rocks' reader takes it back, and a second write must be
// byte-identical -- a document survives being opened and saved.
#import <Stdio.xc>
#import "UXRscModel.xc"
#import "UXRscRead.xc"
#import "UXRscWrite.xc"
#import "UXRscV2.xc"

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
// pre-order index of `o` in `t`, or -1
i32 indexIn(UXRscTree* t, UXRscObject* o)
    {
    Array<UXRscObject>* all = t.allObjects();
    for (u32 k = (u32)0; k < all.count(); k = k + (u32)1)
        {
        if ((UXRscObject* ?)all.get(k) == o)
            {
            return (i32)k;
            }
        }
    return (i32)-1;
    }
UXRscObject* byLogical(UXRscTree* t, i32 id)
    {
    Array<UXRscObject>* all = t.allObjects();
    for (u32 k = (u32)0; k < all.count(); k = k + (u32)1)
        {
        UXRscObject* o = (UXRscObject* ?)all.get(k);
        if (o.logicalId == id)
            {
            return o;
            }
        }
    return (UXRscObject*)0;
    }

void main(void)
    {
    gFails = (i32)0;

    // the registry's numbers are UXKit's
    check((u8*)"UXR_V_DESKTOP is UX_FORM_DESKTOP", (i32)UXR_V_DESKTOP, (i32)UX_FORM_DESKTOP);
    check((u8*)"UXR_V_TABLET is UX_FORM_TABLET", (i32)UXR_V_TABLET, (i32)UX_FORM_TABLET);
    check((u8*)"UXR_V_PHONE is UX_FORM_PHONE", (i32)UXR_V_PHONE, (i32)UX_FORM_PHONE);
    check((u8*)"UXR_V_ANY is UX_FORM_ANY", (i32)UXR_V_ANY, (i32)UX_FORM_ANY);
    check((u8*)"UXR_V_ORIENT_PORTRAIT is UX_ORIENT_PORTRAIT", (i32)UXR_V_ORIENT_PORTRAIT, (i32)UX_ORIENT_PORTRAIT);
    check((u8*)"UXR_V_ORIENT_LANDSCAPE is UX_ORIENT_LANDSCAPE", (i32)UXR_V_ORIENT_LANDSCAPE, (i32)UX_ORIENT_LANDSCAPE);

    // A document: MAIN (a box holding a label, a field and an OK button) and a standalone ALERT.
    UXRscDoc* r = new UXRscDoc();
    UXRscTree* main = new UXRscTree();
    main.name = (u8*)"MAIN";
    main.root = UXRscObject.make((i32)UXR_T_BOX, (i32)0, (i32)0, (i32)320, (i32)200);
    UXRscObject* label = UXRscObject.make((i32)UXR_T_STRING, (i32)10, (i32)10, (i32)80, (i32)16);
    label.text = (u8*)"Name:";
    UXRscObject* field = UXRscObject.make((i32)UXR_T_FIELD, (i32)100, (i32)10, (i32)200, (i32)16);
    field.ted.text = (u8*)"";
    field.ted.tmplt = (u8*)"________";
    UXRscObject* ok = UXRscObject.make((i32)UXR_T_BUTTON, (i32)240, (i32)170, (i32)70, (i32)20);
    ok.text = (u8*)"OK";
    main.root.addChild(label);
    main.root.addChild(field);
    main.root.addChild(ok);
    r.addTree(main);
    UXRscTree* alert = new UXRscTree();
    alert.name = (u8*)"ALERT";
    alert.root = UXRscObject.make((i32)UXR_T_BOX, (i32)0, (i32)0, (i32)200, (i32)80);
    r.addTree(alert);

    // A plain document writes plain classic: no chunk at all.  (Names need the chunk: the classic
    // file has nowhere for them, so they are taken off for this check and put back after it.)
    main.name = (u8*)"";
    alert.name = (u8*)"";
    Data* plain = UXRscWriter.write(r);
    i32 rs = ((i32)plain.byteAt((i32)34) << (i32)8) | (i32)plain.byteAt((i32)35);
    check((u8*)"no variants or names: the file ends at rsh_rssize", plain.length(), rs);
    main.name = (u8*)"MAIN";
    alert.name = (u8*)"ALERT";
    check((u8*)"no forms yet", r.formCount(), (i32)0);

    // ---- adding layouts -------------------------------------------------------
    UXRscTree* pp = r.addVariant(main, (i32)UXR_V_PHONE, (i32)UXR_V_ORIENT_PORTRAIT);
    checkTrue("a phone-portrait layout is added", pp != (UXRscTree*)0);
    check((u8*)"MAIN became a form", r.formCount(), (i32)1);
    UXRscForm* fm = r.formOf(main);
    checkTrue("...which both trees belong to", fm != (UXRscForm*)0 && r.formOf(pp) == fm);
    check((u8*)"its id is MAIN's tree index", fm.formId, (i32)0);
    check((u8*)"MAIN is its desktop layout", fm.variantFor(main).klass, (i32)UXR_V_DESKTOP);
    checkTrue("every MAIN object got a logical id",
              main.root.logicalId != (i32)0 && label.logicalId != (i32)0 && field.logicalId != (i32)0 && ok.logicalId != (i32)0);
    checkTrue("...all different", label.logicalId != field.logicalId && field.logicalId != ok.logicalId && label.logicalId != ok.logicalId);
    UXRscObject* pok = byLogical(pp, ok.logicalId);
    checkTrue("the phone copy carries them", pok != (UXRscObject*)0 && pok != ok);
    checkTrue("the variant tree is named after the form", UXRscWriter.seq(pp.name, (u8*)"MAIN_PHONE_P"));
    // a one-time seed, not a live link
    UXRscObject* pfield = byLogical(pp, field.logicalId);
    pfield.x = (i32)4;
    pfield.ted.tmplt = (u8*)"____";
    check((u8*)"moving the phone's field leaves the desktop's", field.x, (i32)100);
    checkTrue("...and its TEDINFO is its own", UXRscWriter.seq(field.ted.tmplt, (u8*)"________"));
    checkTrue("the same layout twice is refused", r.addVariant(main, (i32)UXR_V_PHONE, (i32)UXR_V_ORIENT_PORTRAIT) == (UXRscTree*)0);
    checkTrue("a desktop orientation is refused", r.addVariant(main, (i32)UXR_V_DESKTOP, (i32)UXR_V_ORIENT_LANDSCAPE) == (UXRscTree*)0);

    // The phone re-nests: OK goes into a scroll-ish box only the phone has (no logical id -- it
    // exists for this layout's benefit), so OK's index differs between the two trees.
    UXRscObject* holder = UXRscObject.make((i32)UXR_T_IBOX, (i32)0, (i32)150, (i32)200, (i32)40);
    pp.root.children.removeAt((u32)2);
    holder.addChild(pok);
    pp.root.addChild(holder);
    check((u8*)"the phone-only container has no id", holder.logicalId, (i32)0);
    // ...and a landscape layout, seeded from the PHONE one (any layout can seed another)
    UXRscTree* pl = r.addVariant(pp, (i32)UXR_V_PHONE, (i32)UXR_V_ORIENT_LANDSCAPE);
    checkTrue("a phone-landscape layout is added from the portrait one", pl != (UXRscTree*)0 && r.formOf(pl) == fm);
    check((u8*)"the form has three layouts", fm.variantCount(), (i32)3);
    checkTrue("the container got an id when it seeded a layout", holder.logicalId != (i32)0);
    checkTrue("...one nobody else had", holder.logicalId > ok.logicalId && holder.logicalId > field.logicalId);
    i32 tMain = r.indexOfTree(main);
    i32 tAlert = r.indexOfTree(alert);
    i32 tP = r.indexOfTree(pp);
    i32 tL = r.indexOfTree(pl);

    // ---- the file, through UXKit's loader -------------------------------------
    Data* bytes = UXRscWriter.write(r);
    UXRscV2* rsc = UXRscV2.open(bytes.bytes(), (u32)bytes.length());
    checkTrue("UXKit's loader opens it", rsc != (UXRscV2*)0);
    if (rsc == (UXRscV2*)0)
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)(gFails));
        return;
        }
    check((u8*)"as version 3", rsc.version(), (i32)3);
    check((u8*)"two forms: MAIN and the standalone ALERT", rsc.formCount(), (i32)2);
    checkTrue("MAIN's name is in it", UXRscWriter.seq(rsc.formName((i32)0), (u8*)"MAIN"));
    i32 cls = (i32)0;
    i32 ori = (i32)0;
    check((u8*)"a phone held upright gets the portrait tree",
          rsc.selectTreeOriented((i32)0, (i32)UX_FORM_PHONE, (i32)UX_ORIENT_PORTRAIT, &cls, &ori), tP);
    check((u8*)"turned on its side, the landscape tree",
          rsc.selectTreeOriented((i32)0, (i32)UX_FORM_PHONE, (i32)UX_ORIENT_LANDSCAPE, &cls, &ori), tL);
    check((u8*)"the desktop gets MAIN", rsc.selectTreeOriented((i32)0, (i32)UX_FORM_DESKTOP, (i32)UX_ORIENT_NONE, &cls, &ori), tMain);
    check((u8*)"a tablet (no layout) falls back to the desktop's", rsc.selectTreeOriented((i32)0, (i32)UX_FORM_TABLET, (i32)UX_ORIENT_PORTRAIT, &cls, &ori), tMain);
    check((u8*)"ALERT loads by its own index", rsc.selectTree(tAlert, (i32)UX_FORM_PHONE, &cls), tAlert);
    check((u8*)"...as `any`", cls, (i32)UX_FORM_ANY);
    check((u8*)"OK binds to the desktop tree's OK", rsc.objForLogical(tMain, ok.logicalId), indexIn(main, ok));
    check((u8*)"and to the phone's, through its re-nesting", rsc.objForLogical(tP, ok.logicalId), indexIn(pp, pok));
    checkTrue("...which really is a different index", indexIn(pp, pok) != indexIn(main, ok));
    check((u8*)"the container is in neither desktop map", rsc.objForLogical(tMain, holder.logicalId), (i32)-1);

    // ---- and back into Rocks --------------------------------------------------
    UXRscDoc* back = UXRscReader.read(bytes.bytes(), bytes.length());
    checkTrue("Rocks reads it back", back != (UXRscDoc*)0);
    if (back == (UXRscDoc*)0)
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)(gFails));
        return;
        }
    check((u8*)"one form (ALERT stands alone again)", back.formCount(), (i32)1);
    UXRscForm* bf = back.formAt((i32)0);
    check((u8*)"with its three layouts", bf.variantCount(), (i32)3);
    checkTrue("MAIN by name", UXRscWriter.seq(bf.name, (u8*)"MAIN") && UXRscWriter.seq(back.treeAt(tMain).name, (u8*)"MAIN"));
    UXRscVariant* bl = bf.find((i32)UXR_V_PHONE, (i32)UXR_V_ORIENT_LANDSCAPE);
    checkTrue("phone-landscape is there, on its tree", bl != (UXRscVariant*)0 && bl.tree == back.treeAt(tL));
    checkTrue("...named after the form", bl != (UXRscVariant*)0 && UXRscWriter.seq(bl.tree.name, (u8*)"MAIN_PHONE_L"));
    UXRscObject* bok = byLogical(back.treeAt(tP), ok.logicalId);
    checkTrue("the phone's OK has its id back", bok != (UXRscObject*)0 && bok.type == (i32)UXR_T_BUTTON && UXRscWriter.seq(bok.text, (u8*)"OK"));
    checkTrue("ALERT is in no form", back.formOf(back.treeAt(tAlert)) == (UXRscForm*)0);
    Data* again = UXRscWriter.write(back);
    bool same = again.length() == bytes.length();
    for (i32 i = (i32)0; same && i < bytes.length(); i = i + (i32)1)
        {
        same = again.byteAt(i) == bytes.byteAt(i);
        }
    Stdio.printf("  (%d bytes, of which the chunk is %d)\n", bytes.length(), bytes.length() - (((i32)bytes.byteAt((i32)34) << (i32)8) | (i32)bytes.byteAt((i32)35)));
    checkTrue("opened and saved again, the file is byte-identical", same);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: layout variants -- forms, logical ids, orientation, the v2 chunk both ways\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
