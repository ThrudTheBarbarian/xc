// shadow-ivar — a local or parameter whose name matches an ivar binds the
// local for the READ and the WRITE alike. The bare-name write used to be
// redirected to the ivar through the implicit-self shorthand, so the value was
// read from the local and stored into the field (bug 562).
class C
    {
    i32 field;

    i32 shadowLocal(void)
        {
        i32 field = (i32)10;
        field = field + (i32)5;
        return field;
        }

    i32 shadowParam(i32 field)
        {
        field = field + (i32)1;
        return field;
        }
    }
