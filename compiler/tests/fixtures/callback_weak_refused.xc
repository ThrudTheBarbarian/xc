//xtc-flags: expect=sema-error
// callback_weak_refused.xc — `weak:` cannot be written on a callback.
//
// Not because it means something else: a stored callback ALWAYS auto-zeroes,
// so the qualifier is implied and there is no other behaviour to ask for
// (LANGUAGE-SPEC §9A.6). What is pinned here is the DIAGNOSTIC. It used to
// read "Unknown type 'weak'" followed by two more errors from the leftover
// colon — because the qualifier scan requires a type after the run, and
// `callback` is a contextual keyword, not a type name.
//
// Every field written against the older `weak:act_t^` spelling hits exactly
// this on the way to `callback`, so the message is the whole migration
// experience for those fields.
#import "Stdio.xc"

class View
{
    weak: callback onTap void(i32 n);
    void init(void) { }
}

i32 main(void)
{
    View* v = new View();
    return 0;
}
