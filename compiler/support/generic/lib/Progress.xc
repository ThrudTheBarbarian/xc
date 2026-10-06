// xcc runtime library.
//
// Copyright (C) 2026 ThrudTheBarbarian@compile-xc.org
//
// This file is part of the xcc runtime library: the code that is combined
// with a program when xcc compiles it. It is free software; you can
// redistribute it and/or modify it under the terms of the GNU General Public
// License as published by the Free Software Foundation, either version 3 of
// the License, or (at your option) any later version.
//
// Under Section 7 of GPL version 3, you are granted additional permissions
// described in the GCC Runtime Library Exception, version 3.1, as published
// by the Free Software Foundation -- see COPYING.RUNTIME in this directory's
// parent.
//
// The effect of that exception is the point: a program compiled by xcc
// contains parts of this file, and the exception is what leaves that program
// under whatever licence its author chooses, including a proprietary one.
//
// This file is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE.
// Progress.xc — how far a piece of work has got, in a tree (NSProgress in
// shape).
// ===========================================================================
//
//     Progress* whole = Progress.withTotal((i64)10);     // ten units of work
//     Progress* copy = whole.makeChild((i64)200, (i64)6); // 200 files, worth 6 of the 10
//     copy.incrementBy((i64)100);                         // half the files
//     whole.incrementBy((i64)2);                          // 2 units of whole's own work
//     whole.fractionCompleted();                          // (2 + 0.5 * 6) / 10 = 0.5
//
// A progress has a total and a completed count of units in whatever measure
// suits it (bytes, files, steps), and may hand a share of its units to child
// progresses that count in their own measure. The fraction completed rolls
// the children up: a child halfway through contributes half the units it was
// given. A long operation reports coarse progress and gives slices to the
// parts that do the work; whoever shows a bar reads the root.
//
// A total of 0 or less is indeterminate: the work cannot yet say how much
// there is. Cancelling a progress cancels its children; the work checks
// isCancelled and stops.
//
// A progress is for one thread, usually the run loop's: a worker reports its
// counts to that thread rather than updating the tree itself.
//
// ── Availability ────────────────────────────────────────────────────────────
//
// Every heap-capable target except xt6502.

#if ARCH_6502
#error "Progress: not available on xt6502"
#endif

#import "Foundation.xc"

class _ProgressChild
    {
    Progress* progress;
    i64 units;  // how many of the parent's units the child stands for
    }

class Progress
    {
    i64 _total;
    i64 _completed;  // the parent's own units, not counting children
    Array* _children;
    bool _cancelled;

    void init(void)
        {
        _total = (i64)0;
        _completed = (i64)0;
        _children = new Array();
        _cancelled = false;
        }

    static Progress* withTotal(i64 total)
        {
        Progress* p = new Progress();
        p._total = total;
        return p;
        }

    // ── Counting ─────────────────────────────────────────────────────────

    i64 totalUnitCount(void)
        {
        return _total;
        }

    void setTotalUnitCount(i64 n)
        {
        _total = n;
        }

    // The units done directly, not counting children.
    i64 completedUnitCount(void)
        {
        return _completed;
        }

    void setCompletedUnitCount(i64 n)
        {
        _completed = n;
        }

    void incrementBy(i64 n)
        {
        _completed = _completed + n;
        }

    // ── Children ─────────────────────────────────────────────────────────

    // Hands `units` of this progress's total to `child`, which counts in its
    // own measure. A child that is cancelled stays in the tree.
    void addChild(Progress* child, i64 units)
        {
        if (child == 0)
            return;
        _ProgressChild* c = new _ProgressChild();
        c.progress = child;
        c.units = units;
        _children.add(c);
        if (_cancelled)
            child.cancel();
        }

    // A new child with `total` units of its own, standing for `units` of this
    // progress's.
    Progress* makeChild(i64 total, i64 units)
        {
        Progress* p = Progress.withTotal(total);
        addChild(p, units);
        return p;
        }

    // ── Reading ──────────────────────────────────────────────────────────

    // 0.0 to 1.0: (own completed + each child's fraction times its units) over
    // the total, kept within 0 and 1. 0 when indeterminate.
    double fractionCompleted(void)
        {
        if (_total <= (i64)0)
            return 0.0d;
        double done = (double)_completed;
        for (u32 i = (u32)0; i < _children.count(); i++)
            {
            _ProgressChild* c = (_ProgressChild*)_children.get(i);
            done = done + c.progress.fractionCompleted() * (double)c.units;
            }
        double f = done / (double)_total;
        if (f < 0.0d)
            return 0.0d;
        if (f > 1.0d)
            return 1.0d;
        return f;
        }

    // The fraction in thousandths, 0 to 1000, rounded down: for a bar drawn
    // in whole steps.
    u32 fractionPerMille(void)
        {
        return (u32)(fractionCompleted() * 1000.0d);
        }

    // Whether the total is not known yet (0 or less).
    bool isIndeterminate(void)
        {
        return _total <= (i64)0;
        }

    bool isFinished(void)
        {
        return _total > (i64)0 && fractionCompleted() >= 1.0d;
        }

    // ── Cancelling ───────────────────────────────────────────────────────

    // Marks this progress and every child cancelled; the work is expected to
    // notice and stop.
    void cancel(void)
        {
        _cancelled = true;
        for (u32 i = (u32)0; i < _children.count(); i++)
            ((_ProgressChild*)_children.get(i)).progress.cancel();
        }

    bool isCancelled(void)
        {
        return _cancelled;
        }
    }
