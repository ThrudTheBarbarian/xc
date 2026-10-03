// field_named_like_type.xc — a field may share its name with a type.
//
// With a type `font` in scope, `font = 5;` inside a method assigns the FIELD
// `font`. A type name starts a declaration only when what follows could begin
// a declarator (another name, a pointer sigil, `^` or `<`); the reference
// parser took any type name not followed by `.` as a declaration and refused
// the assignment.

#import "Stdio.xc"

struct font
    {
    i32 size;
    }

class Ted : Object
    {
    i32 font;
    void init(void)
        {
        font = (i32)5;
        font = font + (i32)1;
        }
    }

i32 main(void)
{
    Ted* t = new Ted();
    font f;
    f.size = (i32)12;
    Stdio.printf("%d %d\n", t.font, f.size);
    return 0;
}
