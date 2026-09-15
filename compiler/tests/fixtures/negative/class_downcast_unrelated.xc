// Downcast between two unrelated classes is a compile-time error.
// The runtime class-id walk would never reach the target, so
// sema rejects the cast regardless of failable marker.
// xtc: error "'Car' and 'Sprite' are unrelated classes"

class Car    { u8 wheels; }
class Sprite { u8 w;      }

void main(void) {
    Car* c = new Car();
    Sprite* s = (Sprite*)c;    // unrelated — can never succeed
}
