---
title: Heap, ARC & weak refs
description: "new and delete, automatic reference counting, and weak: references."
---

xcc has a coalescing free-list heap with reference-counted ownership. It is available on any memory layout that declares a `[heap]` region (the shipped 6502 `xt` layouts do) and on all five native backends. On those targets `-falloc=heap` is the default. A layout without a `[heap]` region falls back to a bump allocator, and heap-only statements are rejected at sema time.

Banked-heap targets reserve one or more 16 KB bank pages for the heap. The runtime selects the right bank on each allocator call.

## Allocation

Three `new` forms cover scalar and array allocation for primitives, structs, and classes. Every successful `new` zero-fills the payload and sets its reference count to 1:

```c
MyClass* p   = new MyClass();       // class instance — init() runs
MyClass* q   = new MyClass(4, 2);   // parameterised init
RGB* pixel   = new RGB;             // struct scalar
u8* buf      = new u8[128];         // array of primitives
MyClass* mob = new MyClass[8];      // array of class instances
```

`new T[N]` is the only way to allocate an array on the heap. For arrays of class instances, every element is zero-filled and its `init()` runs. On out-of-memory, `new` returns null, so check the result if you need to.

## Automatic reference counting (ARC)

The compiler manages reference counts automatically. ARC is always on. Every heap block has a header immediately before the payload. The header shape is **per target**, but on every target the 16-bit retain count sits at `obj-2`, so the back ends emit the same retain/release sequence.

**xt6502**: a 7-byte header in a hand-written coalescing free list:

- 15-bit size
- 1 free-flag bit
- 16-bit retain count

The size field is 15 bits because the free flag takes the top bit of the second
byte, so a single block is capped at **32 KB**. In practice the cap is lower,
because one heap block lives inside one bank. See
[Memory models](/compiler/usage/memory-models/).

**arm64, x86_64, win64, arm9, m68k**: a 24-byte header over the host
allocator, holding a `'BOTX'` cookie, the element stride, the element count,
the `dealloc` pointer, and the same 16-bit refcount at `obj-2`. Size is a `u32`
count × `u32` stride, so **there is no 15-bit limit** on these targets. A block
is bounded by what the host allocator provides.

The compiler emits retain / release operations at these points:

| Event | What the compiler emits |
|-------|--------------------------|
| `Foo* a = new Foo()` | take the allocator's +1; no extra retain |
| `Foo* b = a` | a borrowed read → retain `a`'s pointee |
| `var = expr` | release the old pointee; retain the new one (if borrowed), or absorb the +1 (if `expr` is a value producer like `new` or a function call) |
| **scope exit** | run that scope's [`defer`](/compiler/language/statements/#defer) bodies, then release every tracked strong class-pointer local, LIFO |
| **class dealloc** | when refcount hits zero, the aggregate walker releases every strong class-pointer ivar recursively before returning the bytes to the free list |

A scope tears down in a fixed order: **defers first, LIFO; then that scope's ARC releases; then outward to the next scope**. A `defer` body can therefore still use the local it cleans up. Every non-local exit follows the same order: an early `return`, a `break`, a `continue`, and a propagating [`throw`](/compiler/language/errors/) all release the strong locals of every scope they leave.

Two calling-convention rules follow:

- **Always-`+1` returns.** A function whose return type is a class pointer hands the caller an owning reference. The callee has already retained it, so the caller does not.
- **Callee-retains-params.** A class-pointer parameter is retained on function entry and released on exit. This is net-neutral if the body uses the pointer only transiently. A store that outlives the call (into a global, or into another heap object's field) keeps the +1 from the entry retain.

`retain`, `release` and `delete` on a class instance are **rejected at compile time**, because the compiler owns class refcounts. `delete` remains valid on a struct or a primitive array, which ARC does not manage.

### A canonical walk-through

```c
void work(void) {
    Foo* a = new Foo();   // take allocator's +1.
    Foo* b = a;           // a borrowed read → retain; refcount = 2.
    a = new Foo();        // release old-a, absorb new +1.
                          //   old-a refcount → 1 (b still holds it).
                          //   new-a refcount = 1.
    // scope exit:
    //   release b → old-a refcount → 0 → dealloc;
    //   release a → new-a refcount → 0 → dealloc.
}
```

## The dealloc callback

When a class pointer's refcount reaches zero, the class's `dealloc(void)` method runs **before** the bytes return to the free list. Every class gets an auto-generated empty `dealloc` stub. Classes that own external state override it:

```c
class Buffer {
    u8* bytes;
    u16 len;

    void init(u16 n) {
        bytes = new u8[n];
        len   = n;
    }

    void dealloc(void) {
        // bytes is a strong class-pointer ivar — the aggregate walker
        // releases it automatically. Override dealloc only for things
        // the compiler can't see (hardware, logging, cache invalidation).
    }
}
```

Releasing an array of class instances (an allocation from `new T[N]`) walks the block and calls `dealloc()` once per element before freeing the whole block. `dealloc` runs **once**, when the last owning reference is dropped.

## Weak references

Reference counting alone leaks on cycles. If `Parent` owns `Child` strongly and `Child` has a back-pointer to `Parent`, each refcount stays at 1 after every external reference drops, and the two keep each other alive. The `weak:` qualifier breaks the cycle:

```c
class Child {
    weak:Parent* dad;     // non-owning back-pointer
    u8 tag;
}

class Parent {
    Child* kid;           // strong, owning
    u8 tag;
}
```

A `weak:T*` slot holds a raw pointer but is **invisible to refcounting**: assigning to it does not retain, and releasing the pointee does not consult it. Each live weak slot is linked onto a chain that hangs off the referent's own heap header. When a refcount reaches zero, the dealloc path walks that object's chain and writes `$00` through every slot pointing at the dying block. Later reads of the slot return null.

```c
Parent* p = new Parent();
p.kid = new Child();
p.kid.dad = p;                   // weak: no retain on p.
// Parent refcount = 1 (held by p).
// Child  refcount = 1 (held by p.kid).
p = (Parent*)0;                  // p's release cascades:
//   Parent refcount → 0; dealloc fires.
//     Aggregate walker releases Parent.kid.
//       Child refcount → 0; dealloc fires.
//         Walker processes Child.dad — it's weak, so the
//         walker just unlinks the slot from Parent's weak
//         chain. No decref.
//     Child freed.
//   Weak walker zeroes any external weak refs to Parent.
//   Parent freed.
// No leak, no dangling pointer — dad would have read as null
// even if we'd stashed it somewhere before p's release.
```

Weak slots come in all the shapes a strong pointer can take:

```c
weak:Foo* g;                     // module-scope global
weak:Foo* local;                 // stack-resident local
weak:Foo* arr[8];                // array of weak slots
struct Row { weak:Foo* owner; }  // struct field
class Observer {
    weak:Subject* target;        // ivar
}
```

:::caution[A callback is already weak, and saying so is an error]
A stored [callback](/compiler/language/bound-methods/) never owns its receiver.
It auto-zeroes when that receiver dies, so an action whose target is gone reads
as null instead of calling into freed memory.

You cannot opt into this. Writing the qualifier is **rejected**:

```c
class Observer {
    weak: callback action void(i32 n);    // error
}
```
```
error: `weak:` is implied on a callback and cannot be written — a stored
callback always auto-zeroes when its receiver dies. Remove the qualifier.
```

Remove the `weak:` and the behaviour is unchanged.
:::

### Rules and limits

- **Class pointers only.** `weak:u8*` and similar are rejected at compile time. The chain head lives in a heap block's refcount header, and non-class pointers do not have one.
- **Use `weak:banked:T*` when the pointee is itself banked.** Bare `weak:T*` in a class ivar uses whatever placement the target uses for a bare `T*`. On banked-heap layouts that is a 2-byte implicit-bank pointer, which suits ivars holding heap-placement pointees. If the weak slot needs a per-instance bank byte (because the pointee is `banked:T*`), write `weak:banked:T*`.
- **Cycle detection is your responsibility.** There is no automatic cycle collector. The `weak:` annotation tells the compiler which edge in a cycle is the non-owning one.
- **Reading is a plain pointer read.** A non-null weak slot always points at a live block (the chain is zeroed *before* the block's dealloc runs), so `if (w != 0) ...` is sufficient. There is no special `weak_load` primitive.

### How it works: no table, no cap

A weak reference needs no budget. The slots are threaded onto an
**intrusive doubly-linked list** whose head lives in the referent's own heap header, so:

- there is **no capacity limit** and nothing to size or overflow;
- a weak store is **O(1)**;
- destroying an object with **no** weak references, which is nearly every object in a
  program, costs **one null test** instead of a scan.

Objects that are never weakly referenced pay nothing for the feature. Closing a window of
~500 objects does not cost ~500 × N comparisons.

:::note[Old `.lnk` files]
A `[weak] entries = N` line in a layout is accepted and ignored. There is nothing to configure.
:::

## No manual mode

Earlier releases documented a manual lifecycle mode, `-farc=off`. The flag never
changed the generated code and is retired: `xcc-bootstrap` accepts it with a
warning that it does nothing, and `xcc` rejects it. Every class instance is
reference counted.

## Introspection

The `Heap` library class (`#import <Heap.xc>`) has static helpers for inspecting the allocator's state at runtime:

| Method | Type | Meaning |
|--------|------|---------|
| `Heap.size()` | `u32` | total free bytes available across every reserved bank, including 4-byte per-block header overhead |
| `Heap.largest()` | `u16` | size of the biggest single free extent. First-fit can't satisfy a request larger than this even if `size()` is bigger |
| `Heap.totalSize()` | `u32` | compile-time heap capacity (summed across all reserved banks) |

## Limits

- **On the 6502, a single block cannot exceed one bank** (~12 KB), the size of the data page holding it. The heap holds far more *in total* (it grows across banks on demand), but no single allocation spans a bank boundary. The native backends have no such limit.
- **Retain counts saturate at `$FFFF`** (65535). This is effectively unlimited for normal ownership patterns; do not work around it with additional retains.
- **On the 6502**, a heap pointer carries its own data bank in its third byte, and the backend re-selects that bank on every dereference. The code window and the data window have *separate* selectors, so a `:banked` function can use the heap without swapping its own code page out.

## Worked example

`new`, ARC, and a `weak:` back-reference that prevents a retain cycle:

```c
// memory.xc — ARC, strong vs weak references, and `delete`.
//
// Every class reference is counted. The compiler inserts retain/release; you
// do not write them. An object dies when the last STRONG reference goes.
#import "Foundation.xc"
#import "Stdio.xc"

class Node : Object
{
    String*  _name;
    Node*    _next;      // strong: keeps the next node alive
    weak Node* _prev;    // weak: does NOT keep the previous node alive

    void init(void) { _name = 0; _next = 0; _prev = 0; }
    static Node* named(string n)
    {
        Node* x = new Node();
        x._name = String.withCString(n);
        return x;
    }
    String* description(void) { return _name; }
    void    link(Node* nxt) { _next = nxt; nxt._prev = self; }
    Node*   next(void)   { return _next; }
    weak Node* prev(void) { return _prev; }
    void dealloc(void) { Stdio.printf("  dealloc %@\n", self); }
}

i32 main(void)
{
    // 1. Ordinary lifetime: `head` is the only reference, so the object
    //    lives until the end of the scope.
    Stdio.print("scope A:\n");
    {
        Node* a = Node.named("A");
        Stdio.printf("  made %@\n", a);
    }
    Stdio.print("  (a is gone)\n");

    // 2. A strong chain. Releasing the head releases the whole chain, in
    //    order, because each node holds the next.
    Stdio.print("scope B:\n");
    {
        Node* b1 = Node.named("B1");
        Node* b2 = Node.named("B2");
        b1.link(b2);
        // b2._prev is WEAK, so the pair is not a retain cycle: without that
        // the two would keep each other alive forever and neither would be
        // freed. Weak is how you break a back-reference.
        Node* fwd = b1.next();
        Stdio.printf("  %@ -> %@, and back: %@\n", b1, fwd, b2.prev());
    }
    Stdio.print("  (chain gone)\n");

    // 3. `delete` is for RAW heap blocks — `new T[N]` of a primitive. It is
    //    rejected on a class instance, because ARC already owns that: the
    //    compiler tells you to let the scope release it. So the two models
    //    never overlap and you cannot double-free.
    Stdio.print("raw buffer:\n");
    u16* buf = new u16[4];
    for (u16 i = (u16)0; i < (u16)4; i = i + (u16)1) buf[i] = i * (u16)11;
    Stdio.printf("  buf[3] = %d, length = %d\n", buf[3], (u16)buf.length);
    delete buf;
    Stdio.print("  (deleted)\n");
    return 0;
}
```

```
scope A:
  made A
  dealloc A
  (a is gone)
scope B:
  B1 -> B2, and back: B1
  dealloc B1
  dealloc B2
  (chain gone)
raw buffer:
  buf[3] = 33, length = 4
  (deleted)
```
