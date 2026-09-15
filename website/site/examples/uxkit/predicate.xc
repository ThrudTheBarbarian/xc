// predicate.xc — a predicate tree: comparisons, AND/OR/NOT, against your objects.
//
// The engine behind a rule editor ("kind is Source AND name contains UX").
// Anything answering valueForKey can be filtered; no window, no driver.
#import <Stdio.xc>
#import "UXPredicate.xc"

// The object under test answers ONE method.
class File : Object <UXEvaluable> {
    u8* name; u8* kind; u8* size;
    void init(void) { name=(u8*)""; kind=(u8*)""; size=(u8*)"0"; }
    static File* make(u8* n, u8* k, u8* s) {
        File* f = new File(); f.name=n; f.kind=k; f.size=s; return f;
    }
    u8* valueForKey(u8* key) {
        if (UXPredicate.streq(key, (u8*)"name")) { return name; }
        if (UXPredicate.streq(key, (u8*)"kind")) { return kind; }
        if (UXPredicate.streq(key, (u8*)"size")) { return size; }
        return (u8*)"";                      // absent keys are empty, not an error
    }
}

void run(u8* what, UXPredicate* p, Array<File>* files) {
    Stdio.printf("%s ->", what);
    for (u16 i = 0; i < files.count(); i = i + 1) {
        File* f = (File* ?)files.get(i);
        if (p.evaluate((UXEvaluable*)f)) { Stdio.printf(" %s", f.name); }
    }
    Stdio.printf("\n");
}

void main(void) {
    Array<File>* files = new Array();
    files.add(File.make((u8*)"README.md",   (u8*)"Markdown", (u8*)"2"));
    files.add(File.make((u8*)"main.xc",     (u8*)"Source",   (u8*)"14"));
    files.add(File.make((u8*)"UXWindow.xc", (u8*)"Source",   (u8*)"9"));
    files.add(File.make((u8*)"logo.png",    (u8*)"Image",    (u8*)"48"));

    run((u8*)"kind is Source           ",
        UXPredicate.equals((u8*)"kind", (u8*)"Source"), files);

    // Numeric comparisons parse BOTH sides as integers, so "14" > "9" is true
    // here where a string compare would say otherwise.
    run((u8*)"size > 9                 ",
        UXPredicate.greaterThan((u8*)"size", (u8*)"9"), files);

    run((u8*)"name contains UX         ",
        UXPredicate.contains_((u8*)"name", (u8*)"UX"), files);

    run((u8*)"Source AND contains UX   ",
        UXPredicate.and(UXPredicate.equals((u8*)"kind", (u8*)"Source"),
                        UXPredicate.contains_((u8*)"name", (u8*)"UX")), files);

    run((u8*)"Source OR Image          ",
        UXPredicate.or(UXPredicate.equals((u8*)"kind", (u8*)"Source"),
                       UXPredicate.equals((u8*)"kind", (u8*)"Image")), files);

    run((u8*)"NOT Source               ",
        UXPredicate.not(UXPredicate.equals((u8*)"kind", (u8*)"Source")), files);

    // MATCHES is a regex SEARCH, not an anchored match.
    run((u8*)"name matches (xc|png)    ",
        UXPredicate.matches((u8*)"name", (u8*)"(xc|png)"), files);
}
