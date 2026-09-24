//xtc-flags: expect=sema-error
// ptr_width_mismatch.xc — a pointer to the WRONG-WIDTH scalar is a refusal.
//
// `i32*` where `i64*` is declared lets the callee write eight bytes into four;
// the other direction leaves the caller's high half untouched, which is how a
// `delta < 0` guard in the ported vectoriser came to be unfirable — the sign
// never reached it. Neither direction was diagnosed before.
// private:docs/bugs/244.
void wide(i64* out) { out[0] = (i64)1; }

void main()
{
    i32 narrow = (i32)0;
    wide(&narrow);                 // REFUSED: 4 -> 8
}
