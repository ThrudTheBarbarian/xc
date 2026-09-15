// textwrap.xc — greedy word wrap. Lines are RANGES into the original string.
//
// Pure arithmetic over a uniform character width, so it runs headless and is
// exactly reproducible. A real backend refines the widths with glyph metrics.
#import <Stdio.xc>
#import "UXTextLayout.xc"

void showLines(u8* text, Array<UXRange>* lines) {
    for (u16 i = 0; i < lines.count(); i = i + 1) {
        UXRange* ln = (UXRange* ?)lines.get(i);
        Stdio.printf("  [%d..%d] ", ln.loc, ln.end() - 1);
        for (i32 c = ln.loc; c < ln.end(); c = c + 1) { Stdio.printf("%c", text[c]); }
        Stdio.printf("\n");
    }
}

void main(void) {
    u8* text = (u8*)"the quick brown fox jumps over the lazy dog";

    // 80px at 8px per character = ten characters a line; it breaks at SPACES.
    Stdio.printf("wrapped to 80px (8px/char):\n");
    Array<UXRange>* lines = UXTextLayout.wrap(text, 80, 8);
    showLines(text, lines);
    Stdio.printf("lineCount agrees: %d\n", UXTextLayout.lineCount(text, 80, 8));

    // No copies: a line is a range INTO the original, so the text is stored once
    // however many times it is re-wrapped.
    UXRange* first = (UXRange* ?)lines.get(0);
    Stdio.printf("first line is chars %d..%d of the SAME string\n",
                 first.loc, first.end() - 1);

    // A word longer than the measure falls back to a hard character break —
    // otherwise it would overflow the column for ever.
    u8* longword = (u8*)"antidisestablishmentarianism ok";
    Stdio.printf("a word wider than the line:\n");
    showLines(longword, UXTextLayout.wrap(longword, 80, 8));

    // Explicit newlines always break, whatever the measure.
    u8* para = (u8*)"one\ntwo three four five six\nseven";
    Stdio.printf("explicit newlines:\n");
    showLines(para, UXTextLayout.wrap(para, 200, 8));
}
