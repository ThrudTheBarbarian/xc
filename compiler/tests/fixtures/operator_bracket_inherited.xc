// A bracket operator is inherited and overridable like any method: Money
// gets `|m|` from Amount, and Debt overrides it. A static bracket operator,
// `⌈x⌉`, is called on its class.
#import <Stdio.xc>

class Amount
    {
    i32 cents;
    i32 size() :operator(|self|) { return cents < 0 ? 0 - cents : cents; }
    static i32 dollars(Amount* a) :operator(⌈a⌉) { return (a.cents + 99) / 100; }
    }

class Money : Amount
    {
    static Money* of(i32 c) { Money* m = new Money(); m.cents = c; return m; }
    }

class Debt : Amount
    {
    static Debt* of(i32 c) { Debt* d = new Debt(); d.cents = c; return d; }
    i32 size() { return 0 - cents; }
    }

i32 main(void)
    {
    Money* m = Money.of(-250);
    Debt* d = Debt.of(-75);
    Amount* a = d;
    Stdio.printf("money %d\n", |m|);
    Stdio.printf("debt %d %d\n", |d|, |a|);
    Stdio.printf("dollars %d\n", ⌈Money.of(1201)⌉);
    return 0;
    }
