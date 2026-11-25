//xtc-flags: expect=sema-error target=wasm32
// A protocol's static member called between web modules passes numbers or a
// pointer to numbers and their count; a string is neither. Both compilers
// place the refusal at the member's type.
// Refused: Fence.note: a protocol's static member called between web modules passes numbers, or a pointer to numbers followed by their count; 'string' is neither

protocol Fence
    {
    static void note(string s);
    }

i32 main(void) { return 0; }
