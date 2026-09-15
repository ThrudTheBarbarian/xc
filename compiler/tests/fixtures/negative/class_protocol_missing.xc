// PR9: a class that claims conformance to a protocol but
// doesn't implement every declared method is a sema error.
// xtc: error "Class 'BrokenSprite' claims conformance to protocol 'Drawable' but doesn't implement 'draw'"

protocol Drawable {
    void draw(void);
}

class BrokenSprite <Drawable>
{
    u8 w;
    // missing draw() implementation
}

void main(void) { }
