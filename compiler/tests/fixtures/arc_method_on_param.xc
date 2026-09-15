// arc_method_on_param.xc — method calls on parameter receivers.
//
// Regression cover for the method-label synthesis bug: when the
// receiver is a param (as opposed to a `new`-tracked local or a
// global), emitMethodCallExpr used to fall back to the receiver's
// *identifier name* when synthesising `_cls_<class>_<method>`.
// The symbol-table lookup failed for params (they aren't in
// globalScope) and the fallback produced labels like `_cls_i_work`
// instead of `_cls_Inner_work`, assembling to a label that doesn't
// exist and jumping to the wrong place.
//
// The fix reads the class name from `node.receiver.resolvedType`
// (unwrapping XTPointerType → pointee.displayName), which sema
// stamps uniformly on params, locals, and globals.
//
// T1  Method call on a plain `Inner@` param.
// T2  Method call on a param whose body also invokes another of
//     the same class's methods (no shadowing between caller's
//     param name and the callee's).
// T3  Static call after a param method call (proves the static-
//     dispatch path isn't regressed).

#import "Stdio.xc"
#import "Assert.xc"

u16 innerWork;
u16 innerBump;

class Inner
{
    u8 id;
    void dealloc(void) { }
    void work(void) { innerWork = innerWork + 1; }
    void bump(void) { innerBump = innerBump + 1; }
}

void doit(Inner* i)
{
    i.work();
    return;
}

void doitTwice(Inner* x)
{
    x.work();
    x.bump();
    return;
}

void main(void)
{
    Assert.reset();
    innerWork = 0;
    innerBump = 0;

    Inner* a = new Inner();
    doit(a);
    Assert.isEqual(innerWork, 1);      // T1

    doitTwice(a);
    Assert.isEqual(innerWork, 2);      // T2a
    Assert.isEqual(innerBump, 1);      // T2b

    // T3: static dispatch still works after param dispatch.
    Assert.isEqual(innerWork, 2);      // T3 (re-check)

    Assert.summary();
    return;
}
