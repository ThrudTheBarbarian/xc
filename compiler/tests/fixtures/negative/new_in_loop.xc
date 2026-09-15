// `new` inside a loop body leaks on every iteration — both the
// decl-init form and the bare expression-statement form should
// be flagged.
// xtc: warn "'new Point()' inside a loop"
// xtc: warn "'new Point()' inside a loop"

class Point
{
    u8 x;
    u8 y;
    void set(u8 nx, u8 ny) { x = nx; y = ny; }
}

void churn(void)
{
    u8 i;
    for (i = 0; i < 10; i = i + 1) {
        Point* p = new Point();     // warn 1: flows into decl
        p.set(i, 0);
        new Point();                // warn 2: bare expression-stmt
    }
}

void main(void) { churn(); }
