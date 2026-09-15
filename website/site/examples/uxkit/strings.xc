// strings.xc — UXText and UXStr: the everyday string work a UI cannot avoid.
//
// Nothing here mutates in place; every result is a fresh buffer. That is what
// makes these safe to call on a literal, on a field, or on a pointer someone
// else still holds.
#import <Stdio.xc>
#import "UXText.xc"
#import "UXString.xc"
#import "UXCharacterSet.xc"

void showParts(u8* label, Array<UXStrItem>* parts) {
    Stdio.printf("%s %d:", label, (i32)parts.count());
    for (i32 i = (i32)0; i < (i32)parts.count(); i = i + (i32)1) {
        Stdio.printf(" [%s]", UXText.partAt(parts, i));
    }
    Stdio.printf("\n");
}

void main(void) {
    // ---- trim ------------------------------------------------------------
    Stdio.printf("trim: '%s'\n", UXText.trimWhitespace((u8*)"   hello world \n"));

    // The set is a parameter, so trimming is not only about whitespace.
    UXCharacterSet* quotes = new UXCharacterSet();
    quotes.addString((u8*)"\"'");
    Stdio.printf("unquote: %s\n", UXText.trim((u8*)"\"quoted\"", quotes));

    // ---- split KEEPS empty fields ----------------------------------------
    // A CSV row's empty cell is a cell: "a,,b" is three fields, not two.
    showParts((u8*)"split a,,b   ->", UXText.split((u8*)"a,,b", (u8)','));
    showParts((u8*)"split a,b,   ->", UXText.split((u8*)"a,b,", (u8)','));
    showParts((u8*)"split ''     ->", UXText.split((u8*)"", (u8)','));

    // ---- tokenize DROPS them ---------------------------------------------
    // Which is what splitting a command line wants: runs of spaces are one gap.
    showParts((u8*)"tokenize     ->",
              UXText.tokenize((u8*)"  ls   -l  /usr  ",
                              UXCharacterSet.whitespaceAndNewlines()));

    // ---- join ------------------------------------------------------------
    Stdio.printf("join: %s\n",
                 UXText.join(UXText.split((u8*)"a,,b", (u8)','), (u8*)" | "));

    // split then join with the same delimiter is the identity, which is only
    // true because split keeps the empties.
    Stdio.printf("round trip: %s\n",
                 UXText.join(UXText.split((u8*)"a,b,", (u8)','), (u8*)","));

    // ---- predicates ------------------------------------------------------
    Stdio.printf("prefix=%d suffix=%d contains=%d\n",
                 UXText.hasPrefix((u8*)"system.fnt", (u8*)"sys") ? 1 : 0,
                 UXText.hasSuffix((u8*)"system.fnt", (u8*)".fnt") ? 1 : 0,
                 UXText.contains((u8*)"system.fnt", (u8*)"tem.f") ? 1 : 0);

    // The empty needle is in everything, and the empty prefix is on everything.
    Stdio.printf("empty needle=%d empty prefix=%d\n",
                 UXText.contains((u8*)"abc", (u8*)"") ? 1 : 0,
                 UXText.hasPrefix((u8*)"abc", (u8*)"") ? 1 : 0);

    // A prefix longer than the string stops at the NUL rather than running off.
    Stdio.printf("long prefix=%d\n",
                 UXText.hasPrefix((u8*)"ab", (u8*)"abcdef") ? 1 : 0);

    // ---- case is ASCII ---------------------------------------------------
    Stdio.printf("case: %s %s\n",
                 UXText.toUpper((u8*)"Grand Bleu"),
                 UXText.toLower((u8*)"Grand Bleu"));

    // ---- UXStr: building a label ----------------------------------------
    // cat() skips the separator when the left side is empty, so accumulating a
    // list needs no "is this the first one" test.
    u8* list = (u8*)"";
    list = UXStr.cat(list, (u8)',', (u8*)"red");
    list = UXStr.cat(list, (u8)',', (u8*)"green");
    list = UXStr.cat(list, (u8)',', (u8*)"blue");
    Stdio.printf("accumulated: %s\n", list);

    Stdio.printf("label: %s\n",
                 UXStr.append(UXStr.append((u8*)"Zoom: ", UXStr.fromInt(150)),
                              (u8*)"%"));

    // ---- numbers ---------------------------------------------------------
    Stdio.printf("fromInt: %s %s %s\n",
                 UXStr.fromInt(0), UXStr.fromInt(-42), UXStr.fromInt(2147483647));
    Stdio.printf("fromHex: %s %s %s\n",
                 UXStr.fromHex((u32)0), UXStr.fromHex((u32)255),
                 UXStr.fromHex((u32)0xDEADBEEF));

    // toInt is a READER, not a validator: it takes what it can and stops.
    Stdio.printf("toInt: '  -17px'=%d 'abc'=%d '12.9'=%d '+8'=%d\n",
                 UXStr.toInt((u8*)"  -17px"), UXStr.toInt((u8*)"abc"),
                 UXStr.toInt((u8*)"12.9"), UXStr.toInt((u8*)"+8"));
}
