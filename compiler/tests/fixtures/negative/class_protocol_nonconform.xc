// PR9: passing a non-conforming class instance to a
// protocol-typed parameter is rejected by sema's subtype check.
// xtc: error "argument 1 of 'render': 'Vehicle' does not conform to protocol 'Drawable'"

protocol Drawable {
    void draw(void);
}

class Vehicle
{
    u8 wheels;
}

void render(Drawable* d) { d.draw(); }

void main(void)
{
    Vehicle* v = new Vehicle();
    render(v);       // Vehicle has no Drawable conformance — error.
}
