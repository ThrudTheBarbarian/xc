// test_rscdoc.xc — the .rsc document model: names survive a save (the NAME section), a deep copy
// is independent of its original, and a document with nothing beyond classic GEM is written as a
// plain classic file.  No views, so it runs on every target.
#import <Stdio.xc>
#import "UXRscModel.xc"
#import "UXRscRead.xc"
#import "UXRscWrite.xc"

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
    check(what, got ? (i32)1 : (i32)0, (i32)1);
    }
bool sameBytes(UXData* a, UXData* b)
    {
    if (a.length() != b.length())
        {
        return false;
        }
    for (i32 i = (i32)0; i < a.length(); i = i + (i32)1)
        {
        if (a.bytes()[i] != b.bytes()[i])
            {
            return false;
            }
        }
    return true;
    }
// whether the bytes carry a nib chunk at rsh_rssize
bool hasChunk(UXData* d)
    {
    u8* b = d.bytes();
    i32 rs = ((i32)b[34] << (i32)8) | (i32)b[35];
    return rs + (i32)4 <= d.length() && b[rs] == (u8)'U' && b[rs + (i32)1] == (u8)'X';
    }

void main(void)
    {
    Stdio.printf("-- a plain document stays classic\n");
    UXRscDoc* plain = UXRscDoc.emptyDialog();
    plain.treeAt((i32)0).name = (u8*)"";
    UXRscObject* ok = UXRscObject.make((i32)UXR_T_BUTTON, (i32)8, (i32)8, (i32)64, (i32)24);
    ok.text = (u8*)"OK";
    plain.treeAt((i32)0).root.addChild(ok);
    checkTrue("no chunk", !hasChunk(UXRscWriter.write(plain)));

    Stdio.printf("-- names survive a save\n");
    UXRscDoc* d = UXRscDoc.emptyDialog();
    UXRscTree* main = d.treeAt((i32)0);
    main.name = (u8*)"PREFS";
    UXRscObject* apply = UXRscObject.make((i32)UXR_T_BUTTON, (i32)8, (i32)8, (i32)64, (i32)24);
    apply.text = (u8*)"Apply";
    apply.name = (u8*)"applyButton";
    main.root.addChild(apply);
    UXRscTree* about = new UXRscTree();
    about.name = (u8*)"ABOUT";
    about.root = UXRscObject.make((i32)UXR_T_BOX, (i32)0, (i32)0, (i32)100, (i32)50);
    d.addTree(about);
    UXData* bytes = UXRscWriter.write(d);
    checkTrue("a chunk carries them", hasChunk(bytes));
    UXRscDoc* r = UXRscReader.read(bytes.bytes(), bytes.length());
    checkTrue("reads", r != (UXRscDoc*)0);
    checkTrue("the first tree's name", UXRscWriter.seq(r.treeAt((i32)0).name, (u8*)"PREFS"));
    checkTrue("a tree in no form keeps its name", UXRscWriter.seq(r.treeAt((i32)1).name, (u8*)"ABOUT"));
    checkTrue("an object's name", UXRscWriter.seq(r.treeAt((i32)0).root.childAt((i32)0).name, (u8*)"applyButton"));
    check("NAME is not kept as an unknown section", (i32)r.extSections.count(), (i32)0);
    checkTrue("a second write is byte-identical", sameBytes(bytes, UXRscWriter.write(r)));

    Stdio.printf("-- a deep copy is independent\n");
    UXRscTree* phone = d.addVariant(main, (i32)UXR_V_PHONE, (i32)UXR_V_ORIENT_PORTRAIT);
    UXRscConnection* c = new UXRscConnection();
    c.kind = (i32)UXR_CONN_ACTION;
    c.src = UXRscRef.make((i32)UXR_REF_LOGICAL, (i32)0, apply.logicalId);
    c.dst = UXRscRef.make((i32)UXR_REF_OWNER, (i32)0, (i32)0);
    c.member = (u8*)"onApply";
    d.connections.add(c);
    UXRscDoc* copy = d.deepCopy();
    UXData* before = UXRscWriter.write(d);
    checkTrue("the copy writes the same bytes", sameBytes(before, UXRscWriter.write(copy)));
    copy.treeAt((i32)0).root.childAt((i32)0).x = (i32)99;
    ((UXRscConnection* ?)copy.connections.get((u32)0)).scope = (u32)8;
    copy.formAt((i32)0).variants.removeAt((u32)1);
    checkTrue("editing the copy leaves the original", sameBytes(before, UXRscWriter.write(d)));
    checkTrue("the copy's form points at the copy's trees", copy.formAt((i32)0).variantAt((i32)0).tree == copy.treeAt((i32)0));
    check("the original keeps its phone layout", d.formAt((i32)0).variantCount(), (i32)2);
    checkTrue("and its phone tree", d.formAt((i32)0).find((i32)UXR_V_PHONE, (i32)UXR_V_ORIENT_PORTRAIT).tree == phone);

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: rsc document -- names, deep copy, plain files stay classic\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
