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

// Array.xc — resizable list of Object*. 32-bit implementation.
// =================================================================
//
// This is the Foundation Array for the machines with 32-bit registers —
// arm64, arm9, m68k and x86_64. The 6502 has its own, tuned for an 8-bit
// CPU and a 12 KB bank: `support/xt6502/lib/Array.xc`. The two share an
// API; they do not share an implementation, and neither pays for the
// other's constraints.
//
// Usage:
//   Array* a = new Array();
//   a.add(Number.with((i32)-42));
//   a.add(String.withCString("hi"));
//
//   for (Object* o in a) {                  // Enumerable
//       Number* n = (Number* ?)o;           // safe-checked downcast
//       if (n != 0) Stdio.printf("%d\n", n.asI16());
//   }
//
// Any class works as an element: a parentless `class X` is an implicit
// child of the built-in Object root, so an `X*` is always an `Object*`.
//
// Storage: a heap-allocated `pointer[]` — one cell per element. Indices
// and counts are `u32`, so the container is bounded by memory rather than
// by an arbitrary 65535 ceiling. A narrower caller index widens at the
// call boundary, so `for (u16 i = ...; i < a.count(); i++)` still compiles
// and still means what it says.
//
// Ownership: the Array holds a +1 strong reference on every element.
// `add` / `insert` retain; `set` releases the outgoing element before
// retaining the incoming one; `removeAt` / `removeFirst` / `removeLast` /
// `removeAll` release the slot they vacate; `dealloc` releases whatever is
// left and then frees the backing buffer.
//
// Capacity grows geometrically — 8, then doubling. `withCapacity` pre-sizes
// when the rough total is known, avoiding the resize copies.
//
// Heap-capable targets only.

#import "Object.xc"
#import "Copying.xc"
#import "Enumerable.xc"
#import "Comparable.xc"

// Retain / release a stored element. The slots are type-erased `pointer`
// cells that ARC cannot see, so the refcount is driven manually through the
// language's own ARC primitives — the same Retain / Release the compiler
// emits for a typed strong reference, and null-safe like them.
void _array_arc_retain(pointer ptr)
    {
    __arc_retain(ptr);
    }

void _array_arc_release(pointer ptr)
    {
    __arc_release(ptr);
    }

// Free a raw slot buffer. `new pointer[N]` comes from the same allocator as
// any object — a heap header with refcount 1 and no destructor — so
// releasing it to zero reclaims it. One primitive, correct on every backend.
//
// This used to be a body of `asm { #if ARCH_6502 ... }`, which meant it freed
// nothing whatsoever on the four non-6502 backends: every Array, Map and Set
// leaked its entire backing buffer on drop. Null-safe.
void _array_slots_free(pointer* buf)
    {
    __arc_release((pointer)buf);
    }

// A comparator over two elements: < 0 if a sorts before b, 0 if they sort
// equally, > 0 if a sorts after — the C / NSComparisonResult convention.
// `Array.sortUsing` takes it as a `^`, so a plain function widens into one and
// a bound method (`&self.byColumn`) carries its receiver along with it.
typedef i8 cmp2_t(Object*, Object*);

// The three shapes the functional methods take. Each is a `^`, so a plain
// function widens into one and a bound method carries its receiver — which is
// what lets a predicate close over state (`&filter.matches`) without a global.
typedef bool pred_t(Object*);     // filtered / firstWhere / anySatisfy …
typedef Object* xform_t(Object*); // mapped
typedef void visit_t(Object*);    // forEach

// The comparator behind `Array.sort()`: defer to the elements' own Comparable
// `compare` slot. sort() has already established that the elements implement it
// (an unimplemented optional method leaves a null vtable slot, so `&e.compare`
// comes back null), which is why this can dispatch without re-checking on every
// single comparison.
//
// A null element sorts first, and an element that turns out not to implement
// compare after all sorts equal — neither can happen through sort(), but a
// caller is free to pass this to sortUsing() directly.
// Value equality between two elements, for `Array.equals`. Every class conforms
// to Comparable — `Object` itself does, with pointer identity — so the cast is
// always sound and an element that defines no value equality falls back to
// being equal only to itself.
//
// Identity is checked first, which also makes two nulls equal.
bool _array_elem_equals(Object* a, Object* b)
    {
    if (a == b)
        return true;
    if (a == 0 || b == 0)
        return false;
    Comparable* ca = (Comparable*)a;
    return ca.equals(b);
    }

i8 _array_natural_cmp(Object* a, Object* b)
    {
    if (a == 0)
        return (b == 0) ? (i8)0 : (i8)-1;
    if (b == 0)
        return (i8)1;
    Comparable* ca = (Comparable*)a;
    callback f i8(Object * other) = &ca.compare;
    if (!f)
        return (i8)0;
    return f(b);
    }

class Array<Enumerable, Copying>
    {
    pointer* _slots; // heap cell buffer, length == _capacity
    u32 _count;      // live elements
    u32 _capacity;   // allocated cells

    void init(void)
        {
        _slots = (pointer*)0;
        _count = (u32)0;
        _capacity = (u32)0;
        }

    // Pre-size the backing store, skipping the geometric-resize copies.
    static Array* withCapacity(u32 cap)
        {
        Array* a = new Array();
        if (cap > (u32)0)
            {
            a._slots = new pointer[cap];
            a._capacity = cap;
            }
        return a;
        }

    // Room for at least one more element: double (from 8), copy across, and
    // reclaim the buffer we copied out of.
    void _grow(void)
        {
        u32 newCap = (_capacity == (u32)0) ? (u32)8 : _capacity * (u32)2;
        pointer* fresh = new pointer[newCap];
        pointer* old = _slots;
        for (u32 i = (u32)0; i < _count; i++)
            {
            fresh[i] = old[i];
            }
        _slots = fresh;
        _capacity = newCap;
        // Only the slot bytes are freed — the elements are relocated, not
        // released, so no refcount moves. Omitting this leaked the old buffer
        // on every growth, on every backend.
        _array_slots_free(old);
        }

    // ── Accessors ────────────────────────────────────────────────
    u32 count(void)
        {
        return _count;
        }
    // alias
    u32 length(void)
        {
        return _count;
        }
    bool isEmpty(void)
        {
        return _count == (u32)0;
        }
    u32 capacity(void)
        {
        return _capacity;
        }

    Object* get(u32 i)
        {
        pointer* s = _slots;
        return (Object*)s[i];
        }

    Object* first(void)
        {
        if (_count == (u32)0)
            return (Object*)0;
        return get((u32)0);
        }

    Object* last(void)
        {
        if (_count == (u32)0)
            return (Object*)0;
        return get(_count - (u32)1);
        }

    // ── Mutation ────────────────────────────────────────────────
    void _writeSlot(u32 i, pointer ptr)
        {
        pointer* s = _slots;
        s[i] = ptr;
        }

    pointer _readSlot(u32 i)
        {
        pointer* s = _slots;
        return s[i];
        }

    void set(u32 i, Object* obj)
        {
        if (i >= _count)
            return;
        // Retain the incoming element BEFORE releasing the outgoing one:
        // `a.set(i, a.get(i))` would otherwise free the object between the
        // two statements and store a dangling pointer.
        _array_arc_retain((pointer)obj);
        _array_arc_release(_readSlot(i));
        _writeSlot(i, (pointer)obj);
        }

    void add(Object* obj)
        {
        if (_count >= _capacity)
            _grow();
        _array_arc_retain((pointer)obj);
        _writeSlot(_count, (pointer)obj);
        _count = _count + (u32)1;
        }

    // Insert at `i`, shifting [i..count-1] up one. `i == count` == `add`.
    void insert(u32 i, Object* obj)
        {
        if (i > _count)
            return;
        if (_count >= _capacity)
            _grow();
        if (_count > i)
            {
            pointer* s = _slots;
            for (u32 j = _count; j > i; j = j - (u32)1)
                {
                s[j] = s[j - (u32)1];
                }
            }
        _array_arc_retain((pointer)obj);
        _writeSlot(i, (pointer)obj);
        _count = _count + (u32)1;
        }

    void removeAt(u32 i)
        {
        if (i >= _count)
            return;
        _array_arc_release(_readSlot(i));
        pointer* s = _slots;
        for (u32 j = i; j + (u32)1 < _count; j = j + (u32)1)
            {
            s[j] = s[j + (u32)1];
            }
        _count = _count - (u32)1;
        }

    void removeFirst(void)
        {
        removeAt((u32)0);
        }

    void removeLast(void)
        {
        if (_count == (u32)0)
            return;
        _array_arc_release(_readSlot(_count - (u32)1));
        _count = _count - (u32)1;
        }

    void removeAll(void)
        {
        for (u32 i = (u32)0; i < _count; i = i + (u32)1)
            {
            _array_arc_release(_readSlot(i));
            }
        _count = (u32)0;
        }

    // ── Insert / remove / replace ────────────────────────────────
    // The NSMutableArray surface M1 found missing (insertObjects:,
    // removeObject:, replaceObjectsInRange:, removeObjectsInRange:, setArray:,
    // isEqualToArray:). All of it is insert/remove/replace over the existing
    // growable buffer, and all of it keeps the container's ownership rule: a
    // slot that goes away is released, a slot that arrives is retained.
    //
    // Ranges CLAMP rather than reject, as `subarray` already does.

    // `replaceObjectAtIndex:` — the same thing as `set`, under the name the
    // Foundation call sites use.
    void replaceAt(u32 i, Object* obj)
        {
        set(i, obj);
        }

    // Insert every element of `other` starting at `at`, order preserved.
    void insertAll(u32 at, Array* other)
        {
        if (other == 0 || other.count() == (u32)0)
            return;
        if (at > _count)
            at = _count;
        // Inserting an Array into ITSELF would read slots that the insertion is
        // busy shifting — take a snapshot first.
        Array* src = (other == self) ? Array.withArray(self) : other;
        u32 n = src.count();
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            insert(at + i, src.get(i));
        }

    // Remove the first element with this IDENTITY (removeObjectIdenticalTo:).
    // Returns whether one was found.
    bool remove(Object* obj)
        {
        u32 i = indexOf(obj);
        if (i == $FFFFFFFF)
            return false;
        removeAt(i);
        return true;
        }

    // Remove the first element EQUAL to this one (removeObject:), by value.
    bool removeEqual(Comparable* obj)
        {
        u32 i = indexOfEqual(obj);
        if (i == $FFFFFFFF)
            return false;
        removeAt(i);
        return true;
        }

    // Remove `len` elements at `at`. One pass of releases and ONE shift, rather
    // than `len` calls to removeAt each shifting the whole tail.
    void removeRange(u32 at, u32 len)
        {
        if (at >= _count)
            return;
        u32 avail = _count - at;
        if (len > avail)
            len = avail;
        if (len == (u32)0)
            return;

        for (u32 i = (u32)0; i < len; i = i + (u32)1)
            _array_arc_release(_readSlot(at + i));

        pointer* s = _slots;
        for (u32 j = at; j + len < _count; j = j + (u32)1)
            s[j] = s[j + len];
        _count = _count - len;
        }

    // Replace `len` elements at `at` with all of `other` — the two lengths need
    // not match.
    void replaceRange(u32 at, u32 len, Array* other)
        {
        // Snapshot BEFORE the removal: `other` may be this same Array, and the
        // removal would then delete what we are about to insert.
        Array* src = (other == 0) ? (Array*)0
                                  : ((other == self) ? Array.withArray(self) : other);
        if (at > _count)
            at = _count;
        removeRange(at, len);
        insertAll(at, src);
        }

    // Become `other` — setArray:.
    void setTo(Array* other)
        {
        if (other == self)
            return;
        removeAll();
        addAll(other);
        }

    // isEqualToArray: — same count, and elements equal PAIRWISE BY VALUE
    // (identity first, then the element's own Comparable equality).
    //
    // Under its own name, NOT as an `equals(Array*)` overload. Array does not
    // define `equals(Object*)` of its own — it inherits Object's identity
    // version — and an added typed overload loses to the inherited one at the
    // call site, silently answering "same pointer?" to a question about
    // contents. (String gets away with the overload because it defines BOTH.)
    // Leaving identity as Array's `equals` is also what keeps an Array usable
    // as a Map key or a Set member, where identity is the contract today.
    bool isEqualToArray(Array* other)
        {
        if (other == self)
            return true;
        if (other == 0)
            return false;
        if (other.count() != _count)
            return false;
        for (u32 i = (u32)0; i < _count; i = i + (u32)1)
            {
            if (!_array_elem_equals(get(i), other.get(i)))
                return false;
            }
        return true;
        }

    // arrayWithObject: / arrayWithObjects: for the small fixed counts that
    // cover the call sites. xtc has no nil-terminated vararg convention to
    // borrow, and a literal list of two or three is what those sites are.
    static Array* with(Object* a)
        {
        Array* out = Array.withCapacity((u32)1);
        out.add(a);
        return out;
        }

    static Array* with(Object* a, Object* b)
        {
        Array* out = Array.withCapacity((u32)2);
        out.add(a);
        out.add(b);
        return out;
        }

    static Array* with(Object* a, Object* b, Object* c)
        {
        Array* out = Array.withCapacity((u32)3);
        out.add(a);
        out.add(b);
        out.add(c);
        return out;
        }

    static Array* with(Object* a, Object* b, Object* c, Object* d)
        {
        Array* out = Array.withCapacity((u32)4);
        out.add(a);
        out.add(b);
        out.add(c);
        out.add(d);
        return out;
        }

    // arrayByAddingObject: — a copy with one more element; the receiver is
    // untouched.
    Array* adding(Object* obj)
        {
        Array* out = Array.withCapacity(_count + (u32)1);
        for (u32 i = (u32)0; i < _count; i = i + (u32)1)
            out.add(get(i));
        out.add(obj);
        return out;
        }

    // ── Destruction ──────────────────────────────────────────────
    // Release every element still held, then free the slot buffer. `_slots`
    // is a raw `pointer*`, not a class pointer, so the automatic aggregate
    // walker does not reclaim it — that is this method's job.
    void dealloc(void)
        {
        u32 i = (u32)0;
        while (i < _count)
            {
            _array_arc_release(_readSlot(i));
            i = i + (u32)1;
            }
        _array_slots_free(_slots);
        }

    // ── Enumerable ───────────────────────────────────────────────
    u32 enumLength(void)
        {
        return _count;
        }
    Object* enumAt(u32 i)
        {
        return get(i);
        }

    // ── Search ───────────────────────────────────────────────────
    // Pointer identity, NOT `.equals(..)` — two distinct Number(42) instances
    // are different elements here. Use indexOfEqual for value semantics.
    u32 indexOf(Object* obj)
        {
        pointer needle = (pointer)obj;
        for (u32 i = (u32)0; i < _count; i++)
            {
            if (_readSlot(i) == needle)
                return i;
            }
        return $FFFFFFFF;
        }

    bool contains(Object* obj)
        {
        return indexOf(obj) != $FFFFFFFF;
        }

    // Value equality: dispatches `equals` on each element through the
    // Comparable protocol slot.
    u32 indexOfEqual(Comparable* obj)
        {
        if (obj == 0)
            return $FFFFFFFF;
        for (u32 i = (u32)0; i < _count; i++)
            {
            Object* e = get(i);
            if (e != 0 && obj.equals(e))
                return i;
            }
        return $FFFFFFFF;
        }

    bool containsEqual(Comparable* obj)
        {
        return indexOfEqual(obj) != $FFFFFFFF;
        }

    // Returned by indexOf / indexOfEqual when the element is not present. A
    // sentinel has to sit outside the valid index range, and $FFFF stopped
    // doing that the moment the container could hold more than 65535 things.
    static u32 notFound(void)
        {
        return $FFFFFFFF;
        }

    // ── Sorting ──────────────────────────────────────────────────
    // In-place quicksort over the slot cells. Only the POINTERS move — no
    // element is retained or released, because sorting doesn't change who owns
    // what, just the order.
    //
    //     a.sortUsing(&byLastName);      // any comparator: free fn, or &obj.m
    //     a.sort();                      // the elements' own Comparable order
    //
    // sortUsing takes a `cmp2_t^` — a bound method or a plain function widened
    // into one — so a comparator can capture a receiver (`&self.byColumn`)
    // without a global.
    void sortUsing(callback cmp i8(Object* a, Object* b))
        {
        if (!cmp)
            return;
        if (_count < (u32)2)
            return;
        _qsort((u32)0, _count - (u32)1, cmp);
        }

    void _qsort(u32 lo, u32 hi, callback cmp i8(Object* a, Object* b))
        {
        // sortUsing checks it, but this helper recurses and is reachable on its
        // own — and a `^` goes null the instant its receiver dies, so the check
        // belongs where the call is (private:docs/Design/bound-methods.md 6).
        if (!cmp)
            return;
        if (lo >= hi)
            return;
        pointer* s = _slots;

        // Lomuto partition, pivot at hi.
        pointer pivot = s[hi];
        u32 i = lo;
        for (u32 j = lo; j < hi; j = j + (u32)1)
            {
            // Guarded not because cmp can be null here (_qsort is only
            // reached through sort, which sets it) but because the
            // unguarded-action warning is RIGHT as a rule — and a library
            // must not teach every hello-world to ignore warnings.
            i8 c = (i8)0;
            if (cmp)
                {
                c = cmp((Object*)s[j], (Object*)pivot);
                }
            if (c <= (i8)0)
                {
                pointer t = s[i];
                s[i] = s[j];
                s[j] = t;
                i = i + (u32)1;
                }
            }
        pointer t = s[i];
        s[i] = s[hi];
        s[hi] = t;

        if (i > lo)
            _qsort(lo, i - (u32)1, cmp);
        _qsort(i + (u32)1, hi, cmp);
        }

    // Sort by the elements' OWN order — Comparable's optional `compare` slot.
    //
    // Returns false, and leaves the array untouched, when the elements do not
    // implement `compare`. Ordering is optional precisely because not every
    // value has one, and inventing an arbitrary order for things that don't
    // define one would be a lie that only surfaces much later, in the output.
    // If you want those sorted, say what the order is: sortUsing(&yourCmp).
    bool sort(void)
        {
        if (_count < (u32)2)
            return true;

        // `&e.compare` on an element that doesn't implement the optional slot
        // is a NULL bound method — that IS respondsTo, no runtime query needed.
        Object* first = get((u32)0);
        if (first == 0)
            return false;
        Comparable* c0 = (Comparable*)first;
        callback probe i8(Object * other) = &c0.compare;
        if (!probe)
            return false;

        sortUsing(&_array_natural_cmp);
        return true;
        }

    // Sorted COPY — the receiver is left alone. The copy holds its own strong
    // reference to every element, as any Array does.
    Array* sortedUsing(callback cmp i8(Object* a, Object* b))
        {
        Array* out = Array.withCapacity(_count);
        for (u32 i = (u32)0; i < _count; i = i + (u32)1)
            out.add(get(i));
        out.sortUsing(cmp);
        return out;
        }

    Array* sorted(void)
        {
        Array* out = Array.withCapacity(_count);
        for (u32 i = (u32)0; i < _count; i = i + (u32)1)
            out.add(get(i));
        out.sort();
        return out;
        }

    // Is the array in non-descending order under `cmp`? Cheap check, useful in
    // tests and as a guard before a merge.
    bool isSortedUsing(callback cmp i8(Object* a, Object* b))
        {
        if (!cmp)
            return false;
        for (u32 i = (u32)1; i < _count; i = i + (u32)1)
            {
            if (cmp(get(i - (u32)1), get(i)) > (i8)0)
                return false;
            }
        return true;
        }

    // ── Functional ───────────────────────────────────────────────
    // Each takes a `^`, so the predicate can be a plain function OR a bound
    // method that carries its receiver — which is the whole point:
    //
    //     class Filter { String* needle;  bool matches(Object* o) { … } }
    //     Array* hits = rows.filtered(&filter.matches);
    //
    // The filter's state lives on the filter, not in a global, and the same
    // Array can be filtered two different ways at once.

    // Elements the predicate keeps, in order. A new Array; the receiver is
    // untouched, and the survivors are retained by the result as normal.
    Array* filtered(callback keep bool(Object* o))
        {
        Array* out = new Array();
        if (!keep)
            return out;
        for (u32 i = (u32)0; i < _count; i = i + (u32)1)
            {
            Object* e = get(i);
            if (keep(e))
                out.add(e);
            }
        return out;
        }

    // Each element through `f`. A null result is skipped rather than stored, so
    // `mapped` doubles as a filtering transform.
    Array* mapped(callback f Object*(Object* o))
        {
        Array* out = Array.withCapacity(_count);
        if (!f)
            return out;
        for (u32 i = (u32)0; i < _count; i = i + (u32)1)
            {
            Object* r = f(get(i));
            if (r != 0)
                out.add(r);
            }
        return out;
        }

    void forEach(callback fn void(Object* o))
        {
        if (!fn)
            return;
        for (u32 i = (u32)0; i < _count; i = i + (u32)1)
            fn(get(i));
        }

    // First element satisfying the predicate, or null. Stops at the first hit.
    Object* firstWhere(callback p bool(Object* o))
        {
        if (!p)
            return (Object*)0;
        for (u32 i = (u32)0; i < _count; i = i + (u32)1)
            {
            Object* e = get(i);
            if (p(e))
                return e;
            }
        return (Object*)0;
        }

    u32 indexWhere(callback p bool(Object* o))
        {
        if (!p)
            return $FFFFFFFF;
        for (u32 i = (u32)0; i < _count; i = i + (u32)1)
            {
            if (p(get(i)))
                return i;
            }
        return $FFFFFFFF;
        }

    u32 countWhere(callback p bool(Object* o))
        {
        u32 n = (u32)0;
        if (!p)
            return n;
        for (u32 i = (u32)0; i < _count; i = i + (u32)1)
            {
            if (p(get(i)))
                n = n + (u32)1;
            }
        return n;
        }

    bool anySatisfy(callback p bool(Object* o))
        {
        return indexWhere(p) != $FFFFFFFF;
        }

    bool allSatisfy(callback p bool(Object* o))
        {
        if (!p)
            return false;
        for (u32 i = (u32)0; i < _count; i = i + (u32)1)
            {
            if (!p(get(i)))
                return false;
            }
        return true;
        }

    // ── Bulk / structural ────────────────────────────────────────
    static Array* withArray(Array* other)
        {
        Array* out = new Array();
        out.addAll(other);
        return out;
        }

    void addAll(Array* other)
        {
        if (other == 0)
            return;
        for (u32 i = (u32)0; i < other.count(); i = i + (u32)1)
            add(other.get(i));
        }

    // A slice as a new Array. Out of range clamps to empty, as String does.
    Array* subarray(u32 from, u32 len)
        {
        Array* out = new Array();
        if (from >= _count)
            return out;
        u32 avail = _count - from;
        u32 n = (len < avail) ? len : avail;
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            out.add(get(from + i));
        return out;
        }

    void swapAt(u32 i, u32 j)
        {
        if (i >= _count || j >= _count || i == j)
            return;
        pointer* s = _slots;
        pointer t = s[i];
        s[i] = s[j];
        s[j] = t;
        }

    // Reverse in place — only the slot cells move, so no refcount changes.
    void reverse(void)
        {
        if (_count < (u32)2)
            return;
        u32 lo = (u32)0;
        u32 hi = _count - (u32)1;
        while (lo < hi)
            {
            swapAt(lo, hi);
            lo = lo + (u32)1;
            hi = hi - (u32)1;
            }
        }

    Array* reversed(void)
        {
        Array* out = Array.withCapacity(_count);
        u32 i = _count;
        while (i > (u32)0)
            {
            i = i - (u32)1;
            out.add(get(i));
            }
        return out;
        }

    // <Copying>: a new Array over the same elements. SHALLOW — the elements
    // are shared, each retained by the new Array so both own independently.
    Array* copy(void)
        {
        return Array.withArray(self);
        }
    }
