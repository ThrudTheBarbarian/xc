// extern-global — a bodyless `extern` global is defined in another module
// (a C library, a framework constant): the symbol carries `extern` and no
// storage is reserved here, so reads go through the GOT to the real object.
extern u16 gOutside;

u16 readOutside(void)
    {
    return gOutside;
    }
