// test_combobox.xc — UXComboBox prefix completion + selection.
#import <Stdio.xc>
#import "UXComboBox.xc"

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
bool streq(u8* a, u8* b)
    {
    i32 i = (i32)0;
    while (a[i] != (u8)0 && b[i] != (u8)0)
        {
        if (a[i] != b[i])
            {
            return false;
            }
        i = i + (i32)1;
        }
    return a[i] == b[i];
    }
void eq(u8* what, u8* got, u8* want)
    {
    if (streq(got, want))
        {
        Stdio.printf("  ok   %s = \"%s\"\n", what, got);
        }
    else
        {
        Stdio.printf("  FAIL %s = \"%s\" (want \"%s\")\n", what, got, want);
        gFails = gFails + (i32)1;
        }
    }

void main(void)
    {
    gFails = (i32)0;
    UXComboBox* cb = new UXComboBox();
    cb.addItem((u8*)"Apple");
    cb.addItem((u8*)"Apricot");
    cb.addItem((u8*)"Banana");
    cb.addItem((u8*)"Cherry");
    check("four items", cb.count(), (i32)4);

    // empty text: no completion, all match
    check("empty completion index -1", cb.completionIndex(), (i32)-1);
    check("empty matches all", cb.matchCount(), (i32)4);

    // prefix "Ap" -> matches Apple + Apricot, completes to Apple (first)
    cb.setText((u8*)"Ap");
    check("Ap matches 2", cb.matchCount(), (i32)2);
    check("Ap completion index 0", cb.completionIndex(), (i32)0);
    eq("Ap completes to Apple", cb.completion(), (u8*)"Apple");

    // case-insensitive
    cb.setText((u8*)"ba");
    check("ba (lower) matches Banana", cb.matchCount(), (i32)1);
    eq("ba completes to Banana", cb.completion(), (u8*)"Banana");

    // no match -> completion is the text itself
    cb.setText((u8*)"Xy");
    check("Xy no match", cb.completionIndex(), (i32)-1);
    eq("Xy completion is the text", cb.completion(), (u8*)"Xy");

    // acceptCompletion fills the text in
    cb.setText((u8*)"Che");
    cb.acceptCompletion();
    eq("accepted completion -> Cherry", cb.text(), (u8*)"Cherry");

    // selectItem commits a suggestion directly
    cb.selectItem((i32)1);
    eq("selectItem -> Apricot", cb.text(), (u8*)"Apricot");

    // narrowing: "Apr" matches only Apricot
    cb.setText((u8*)"Apr");
    check("Apr matches 1", cb.matchCount(), (i32)1);
    eq("Apr completes to Apricot", cb.completion(), (u8*)"Apricot");

    if (gFails == (i32)0)
        {
        Stdio.printf("PASS: UXComboBox — prefix completion, case-insensitive, no-match, accept, select.\n");
        }
    else
        {
        Stdio.printf("FAIL: %d check(s)\n", (i16)gFails);
        }
    }
