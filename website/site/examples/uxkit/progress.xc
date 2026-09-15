// progress.xc — UXProgress: a tree of sub-tasks that rolls up into one figure.
//
// Integer arithmetic in per mille, so the roll-up is exact at every level and
// identical on every backend. No driver, no window.
#import <Stdio.xc>
#import "UXProgress.xc"

void show(u8* label, UXProgress* p) {
    Stdio.printf("%s mille=%d pct=%d finished=%d\n",
                 label, p.fractionMille(), p.percent(),
                 p.isFinished() ? 1 : 0);
}

void main(void) {
    // ---- a flat progress ---------------------------------------------------
    UXProgress* flat = UXProgress.make((i32)200);
    show((u8*)"start:      ", flat);
    flat.setCompleted((i32)50);
    show((u8*)"50/200:     ", flat);
    flat.incrementBy((i32)150);
    show((u8*)"+150:       ", flat);

    // ---- a tree ------------------------------------------------------------
    // The parent has 100 units and delegates 80 of them: 70 to a big sub-task
    // and 10 to a small one, keeping 20 units of work for itself.
    UXProgress* job = UXProgress.make((i32)100);
    UXProgress* copyFiles = job.addChild((i32)3500, (i32)70);   // 3500 files
    UXProgress* verify    = job.addChild((i32)12,   (i32)10);   // 12 steps

    show((u8*)"nothing yet:", job);

    // The child counts in ITS units; the parent only knows the share.
    copyFiles.setCompleted((i32)1750);                          // half the files
    show((u8*)"files 50%:  ", job);
    Stdio.printf("   (the child itself reads %d%%)\n", copyFiles.percent());

    verify.setCompleted((i32)12);                               // verify done
    show((u8*)"+verify:    ", job);

    // The parent's own 20 units are tracked by its completed count.
    job.setCompleted((i32)20);
    show((u8*)"+own work:  ", job);

    copyFiles.setCompleted((i32)3500);
    show((u8*)"all done:   ", job);

    // ---- indeterminate -----------------------------------------------------
    // A total of zero means "no idea how much there is" — a spinner, not a bar.
    UXProgress* unknown = UXProgress.make((i32)0);
    Stdio.printf("indeterminate=%d mille=%d\n",
                 unknown.isIndeterminate() ? 1 : 0, unknown.fractionMille());
    unknown.setTotal((i32)10);
    Stdio.printf("after setTotal(10): indeterminate=%d\n",
                 unknown.isIndeterminate() ? 1 : 0);

    // ---- edges -------------------------------------------------------------
    // Over-completing clamps rather than running past the end.
    UXProgress* over = UXProgress.make((i32)10);
    over.setCompleted((i32)999);
    show((u8*)"over:       ", over);

    // Nesting goes as deep as you like; each level rolls up the one below.
    UXProgress* outer = UXProgress.make((i32)100);
    UXProgress* mid   = outer.addChild((i32)100, (i32)100);
    UXProgress* inner = mid.addChild((i32)4, (i32)100);
    inner.setCompleted((i32)1);
    Stdio.printf("nested: inner=%d%% mid=%d%% outer=%d%%\n",
                 inner.percent(), mid.percent(), outer.percent());
}
