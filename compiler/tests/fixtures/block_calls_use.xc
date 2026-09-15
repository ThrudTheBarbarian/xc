// block_calls_use.xc — a `#use`d static called BARE inside a block literal.
//
// `#use Stdio` promotes Stdio's statics into the bare-call space for the
// whole file, and a block body is in the file. The reference compiler
// refused this ("Call to undeclared function 'printf'") because a block
// literal is a method of a synthesised class and use-promotion was switched
// off inside every class body; the shipped compiler accepted it (bug 145).
// Both now resolve it the same way: implicit-self methods and free functions
// first, the `use` list last.
#use Stdio
i32 main(void)
{
    block void(u32 n) b = block void(u32 n) { printf("in block %lu\n", n); };
    b((u32)7);
    return 0;
}
