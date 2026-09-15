class SLib
    {
    // the APP's object
    static u32 lenOf(String* s)
        {
        return s.byteLength();
        }
    static u32 lenOwn(void) // the LIBRARY's own
        {
        String* t = String.withCString("xyz");
        return t.byteLength();
        }
    }
