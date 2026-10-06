//xtc-na: xt6502 — Expression is not available on xt6502
// foundation_expression.xc — Expression: precedence, exact integers and
// doubles, comparisons and short-circuit logic, functions, variables from a
// Map, and the parse and evaluation errors.
#import "Foundation.xc"
#import "Expression.xc"

i32 gFails;
String* S(u8* c)
    {
    return String.withCString(c);
    }
// Evaluates `text` with `vars` and prints the result, or the error.
void show(u8* text, Map* vars)
    {
    try
        {
        Expression* e = Expression.parse(S(text));
        Number* v = e.evaluate(vars);
        Stdio.printf("%-28s = %@%s\n", text, v, v.isFloat() ? " (double)" : (v.isBool() ? " (bool)" : ""));
        }
    catch (ExpressionError e)
        {
        Stdio.printf("%-28s ! %s\n", text, e.message().cString());
        }
    }

i32 main(void)
    {
    gFails = (i32)0;
    Map* vars = new Map();
    vars.set(S("qty"), Number.withI64((i64)3));
    vars.set(S("price"), Number.withI64((i64)200));
    vars.set(S("tax"), Number.withDouble(12.5d));
    vars.set(S("big"), Number.withI64((i64)9223372036854775807));
    vars.set(S("name"), S("not a number"));

    show("1 + 2 * 3", vars);
    show("(1 + 2) * 3", vars);
    show("qty * price + tax", vars);
    show("qty * price", vars);
    show("7 / 2", vars);
    show("-7 / 2", vars);
    show("-7 % 3", vars);
    show("7.0 / 2", vars);
    show("7.5 % 2", vars);
    show("0x10 + 1", vars);
    show("1e3 + 0.5", vars);
    show("big + 1", vars);
    show("2 < 3 && 3 <= 3", vars);
    show("1 == 1.0", vars);
    show("!(qty > 2) || false", vars);
    show("0 && missing", vars);
    show("1 || missing", vars);
    show("min(5, qty, 9)", vars);
    show("max(1, 2.5, 2)", vars);
    show("abs(-4) + abs(-1.5)", vars);
    show("- - 3", vars);

    show("missing + 1", vars);
    show("name + 1", vars);
    show("1 / 0", vars);
    show("1 % 0", vars);
    show("1.0 / 0", vars);
    show("1 +", vars);
    show("(1 + 2", vars);
    show("1 2", vars);
    show("sqrt(4)", vars);
    show("abs(1, 2)", vars);
    show("99999999999999999999", vars);

    Expression* e = (Expression*)0;
    try
        {
        e = Expression.parse(S("a * b + a - c"));
        }
    catch (ExpressionError x)
        {
        }
    Array* names = e.variables();
    Stdio.printf("variables:");
    for (u32 i = (u32)0; i < names.count(); i++)
        Stdio.printf(" %@", names.get(i));
    Stdio.printf("\n");
    try
        {
        Stdio.printf("no variables: %@\n", Expression.parse(S("2 * 21")).evaluate());
        }
    catch (ExpressionError x)
        {
        }
    return gFails;
    }
