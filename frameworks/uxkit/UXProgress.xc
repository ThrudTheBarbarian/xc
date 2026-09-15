// UXProgress.xc — hierarchical progress reporting (NSProgress in shape).
//
// A progress has a total unit count and its own completed units, plus optional CHILD progresses each
// allocated a share of the total; the overall fraction rolls the children up (a child 50% done
// contributes half of its allocated units).  A long operation reports coarse progress and delegates
// slices to sub-tasks that report their own — the tree aggregates.  fractionMille is 0..1000 (per
// mille) so it stays exact in integer maths.
#import "Array.xc"

class UXProgressChild : Object
    {
    UXProgress* prog;
    i32 units; // how many of the parent's total units this child represents
    void init(void)
        {
        prog = (UXProgress*)0;
        units = (i32)0;
        }
    }

    class UXProgress
    {
    i32 total;     // total units (own + those allocated to children)
    i32 completed; // own directly-completed units (not counting children)
    Array<UXProgressChild>* children;
    void init(void)
        {
        total = (i32)1;
        completed = (i32)0;
        children = new Array();
        }

    static UXProgress* make(i32 total)
        {
        UXProgress* p = new UXProgress();
        p.total = total;
        return p;
        }

    void setTotal(i32 n)
        {
        total = n;
        }
    void setCompleted(i32 n)
        {
        completed = n;
        if (completed > total)
            {
            completed = total;
            }
        }
    void incrementBy(i32 n)
        {
        self.setCompleted(completed + n);
        }

    // Allocate `unitsInParent` of this progress's total to a new child sub-task of its own size.
    UXProgress* addChild(i32 childTotal, i32 unitsInParent)
        {
        UXProgress* c = UXProgress.make(childTotal);
        UXProgressChild* pc = new UXProgressChild();
        pc.prog = c;
        pc.units = unitsInParent;
        children.add(pc);
        return c;
        }

    bool isIndeterminate(void)
        {
        return total <= (i32)0;
        }

    // Overall completion in per mille (0..1000): (own completed + Σ child.fraction·child.units) / total.
    i32 fractionMille(void)
        {
        if (total <= (i32)0)
            {
            return (i32)0;
            }
        i32 done = completed;
        for (u16 i = (u16)0; i < children.count(); i = i + (u16)1)
            {
            UXProgressChild* c = (UXProgressChild* ?)children.get(i);
            done = done + c.prog.fractionMille() * c.units / (i32)1000;
            }
        i32 f = done * (i32)1000 / total;
        if (f > (i32)1000)
            {
            f = (i32)1000;
            }
        if (f < (i32)0)
            {
            f = (i32)0;
            }
        return f;
        }
    // Convenience: 0..100 percent.
    i32 percent(void)
        {
        return self.fractionMille() / (i32)10;
        }
    bool isFinished(void)
        {
        return self.fractionMille() >= (i32)1000;
        }
    }
