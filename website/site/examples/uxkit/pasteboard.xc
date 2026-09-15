// pasteboard.xc — one payload per TYPE, so a copy can offer the same thing
// several ways and a paste picks the richest form it understands.
#import <Stdio.xc>
#import "UXPasteboard.xc"

void main(void) {
    UXPasteboard* pb = UXPasteboard.general();      // the clipboard

    // A copy offers its content in several forms at once.
    pb.clearContents();
    pb.setString((u8*)"<b>Report</b>", (u8*)"public.html");
    pb.writeText((u8*)"Report");                     // public.utf8-plain-text
    Stdio.printf("types offered: %d  change count: %d\n", pb.typeCount(), pb.changeCount);
    for (i32 i = 0; i < pb.typeCount(); i = i + 1) {
        Stdio.printf("  %s\n", pb.typeAt(i));
    }

    // A paste asks for the richest form IT understands, not the first written.
    u8* want = pb.preferredType((u8*)"public.html", (u8*)"public.utf8-plain-text");
    Stdio.printf("an HTML-capable paste takes: %s -> %s\n", want, pb.stringForType(want));

    u8* plainOnly = pb.preferredType((u8*)"public.rtf", (u8*)"public.utf8-plain-text");
    Stdio.printf("a plain-text-only paste takes: %s -> %s\n", plainOnly, pb.stringForType(plainOnly));

    // An absent type is null, not an error.
    Stdio.printf("has public.file-url: %s  value: %s\n",
                 pb.hasType((u8*)"public.file-url") ? (u8*)"yes" : (u8*)"no",
                 pb.stringForType((u8*)"public.file-url") == (u8*)0 ? (u8*)"(null)" : (u8*)"?");

    // CLEARING IS A WRITE: it bumps the change count and drops every type.
    i32 before = pb.changeCount;
    pb.clearContents();
    Stdio.printf("after clear: types=%d change count %d -> %d\n",
                 pb.typeCount(), before, pb.changeCount);

    // A drag carries its OWN pasteboard, not the clipboard — so dragging
    // something does not destroy what the user copied earlier.
    UXPasteboard* dragPb = new UXPasteboard();
    dragPb.writeText((u8*)"dragged item");
    Stdio.printf("drag pasteboard is separate: clipboard types=%d drag types=%d\n",
                 UXPasteboard.general().typeCount(), dragPb.typeCount());
}
