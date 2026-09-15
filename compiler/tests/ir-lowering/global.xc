// global — pins the module-level variable lowering. The top-level
// `counter` decl registers a DataGlobal symbol; reads emit AddrOf
// %sym + Load, writes emit AddrOf %sym + Store, and `&counter`
// emits a bare AddrOf %sym. The pinned-local pre-scan also picks
// counter up via `&counter` so we exercise the symbol-keyed
// AddrOf path side by side with pinned-local AddrOf.
u16 counter;

u16 bump(void)
    {
    counter = counter + 1;
    return counter;
    }
