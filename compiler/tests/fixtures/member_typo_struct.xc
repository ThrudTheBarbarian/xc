//xtc-flags: expect=sema-error
// A struct field that doesn't exist must be a hard ERROR.
//
// It used to resolve silently to u8 in sema; IR lowering then couldn't find the
// field, emitted a NOTE ("struct 'X' has no field 'Y'"), abandoned the
// construct — and the compile SUCCEEDED with the store DROPPED.
//
// For a DWARF-imported C struct that is lethal: renaming a field in a C header
// turns every write to the old name into a silently-lost store rather than a
// build failure. (Found porting GEM: `ob_width` for `ob_w`.)

struct Obj { u16 ob_x; u16 ob_w; }

void main(void)
{
    Obj o;
    o.ob_width = (u16)42;      // no such field -> must not compile
}
