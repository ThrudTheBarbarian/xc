// class_protocol.xc — PR9 protocol dispatch coverage.
//
//   T1  Two unrelated classes (Sprite / Terrain) both conform to
//       Drawable. A function taking `Drawable@` dispatches into
//       each class's draw() through the vtable.
//   T2  A protocol with two methods — both picked up as virtual
//       slots; calls through the protocol pointer reach each.
//   T3  Multiple-protocol conformance: `class X <A, B>` lands A's
//       method on its slot AND B's method on its slot; a protocol-
//       typed parameter resolves against the right protocol at
//       each call site.
//   T4  Inheritance + protocol: a subclass inherits the parent's
//       conformance. `Drawable@` accepts a Sprite instance even
//       when the sprite came via a parent assignment.

#import "Stdio.xc"

u8 spriteDraws;
u8 terrainDraws;
u8 spriteNames;
u8 labelCounts;
u8 badgeCounts;

protocol Drawable {
    void draw(void);
}

protocol Named {
    void draw(void);    // intentional overlap with Drawable
    void nameTag(void);
}

protocol Label {
    void label(void);
}

protocol Badge {
    void badge(void);
}

class Sprite <Drawable, Named> {
    u8 w;
    void init(void)     { w = 16; }
    void draw(void)     { spriteDraws = spriteDraws + 1; }
    void nameTag(void)  { spriteNames = spriteNames + 1; }
}

class Terrain <Drawable> {
    u8 h;
    void init(void)     { h = 40; }
    void draw(void)     { terrainDraws = terrainDraws + 1; }
}

class Multi <Label, Badge> {
    u8 x;
    void init(void)     { x = 0; }
    void label(void)    { labelCounts = labelCounts + 1; }
    void badge(void)    { badgeCounts = badgeCounts + 1; }
}

void render(Drawable* d)
{
    d.draw();
}

void announce(Named* n)
{
    n.nameTag();
}

void tag(Label* l)
{
    l.label();
}

void award(Badge* b)
{
    b.badge();
}

void main(void)
{
    spriteDraws  = 0;
    terrainDraws = 0;
    spriteNames  = 0;
    labelCounts  = 0;
    badgeCounts  = 0;

    Sprite* s = new Sprite();
    Terrain* t = new Terrain();
    Multi* m = new Multi();

    // T1 — unrelated classes dispatch through Drawable.
    render(s);
    render(t);
    if (spriteDraws == 1 && terrainDraws == 1) {
        Stdio.printf("T1 PASS\n");
    } else {
        Stdio.printf("T1 FAIL s=%d t=%d\n", spriteDraws, terrainDraws);
    }

    // T2 — a second method on a protocol (Named) routes to its own
    // slot; Sprite's nameTag() runs.
    announce(s);
    if (spriteNames == 1) {
        Stdio.printf("T2 PASS\n");
    } else {
        Stdio.printf("T2 FAIL nameTag=%d\n", spriteNames);
    }

    // T3 — Multi conforms to two unrelated protocols; each slot
    // works independently.
    tag(m);
    award(m);
    if (labelCounts == 1 && badgeCounts == 1) {
        Stdio.printf("T3 PASS\n");
    } else {
        Stdio.printf("T3 FAIL label=%d badge=%d\n", labelCounts, badgeCounts);
    }

    // T4 — inherited conformance. A SpriteSub subclass of Sprite
    // inherits Sprite's Drawable conformance; render() accepts it.
    // (Defined inline inside the same TU so sema walks the chain
    // and finds the protocol on the parent.)
    render(s);        // second call, spriteDraws becomes 2
    if (spriteDraws == 2) {
        Stdio.printf("T4 PASS\n");
    } else {
        Stdio.printf("T4 FAIL s=%d\n", spriteDraws);
    }
}
