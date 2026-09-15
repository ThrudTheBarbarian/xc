struct rec
    {
    void* p;          // C/ARM: offset 0, 4 bytes
    short x;          // offset 4
    struct rec* next; // offset 8 — self-referential (exercises cycle break)
    };

int rec_x(struct rec* r)
    {
    return r->x;
    }
