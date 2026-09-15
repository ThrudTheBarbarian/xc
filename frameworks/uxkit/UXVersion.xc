// UXVersion.xc — libUXKit.so is major.minor.patch, and the ABI lives in the SYMBOL NAME.
//
// A client compiled against one libUXKit.so and run against another does not fail politely: it
// jumps through a stale vtable offset and dies as PC=0, PREFETCH-ABORT, naming neither the
// library nor the mismatch. In a tree where three threads rebuild each other's libraries,
// that will keep happening. So:
//
//   major   a conceptual redesign. A different library, in effect.
//   minor   AN ABI BREAK — the layout moved. A client built against 1.0 CANNOT run on 1.1.
//   patch   compatible: additions and fixes. 1.0.7 satisfies a client that needs 1.0.4.
//
// The three are enforced in two different places, because they need different rules:
//
//   major.minor -> THE SYMBOL NAME. libUXKit.so defines UXKit_abi_1_0; a client CALLS it. Bump the
//                  minor and that symbol ceases to exist, so the LOADER refuses the stale
//                  client, by name, before main() runs:
//
//                      xtld_load err: UXKit_abi_1_0 rc=undefined symbol
//
//                  Exact-match by construction — which is what an ABI break MEANS — and it
//                  cannot be outrun: a stale layout cannot crash us before a check the loader
//                  itself performs. That is why this is not a version compared at start-up.
//
//   patch       -> A RETURNED NUMBER. UXKit_abi_1_0() returns the patch level, so a client asks
//                  for a MINIMUM and a newer library still satisfies it. An exact match here
//                  would be wrong: that is the whole difference between `patch` and `minor`,
//                  and it is what a content hash of the sources could never express.
//
// Bump MINOR when the layout moves: a field added to a class, a method added to one that a
// client subclasses, anything that shifts an offset or a vtable slot.

#define UXK_MAJOR 1
#define UXK_MINOR 0
#define UXK_PATCH 0

// Build the symbol name from the numbers. The two-level form is required: CAT2 pastes its
// arguments RAW, so CAT expands them first — otherwise the name would come out `UXKit_abi_UXK_MAJOR`.
#define UXK_CAT2(a, b) a##b
#define UXK_CAT(a, b) UXK_CAT2(a, b)
#define UXK_ABI_SYM UXK_CAT(UXK_CAT(UXKit_abi_, UXK_MAJOR), UXK_CAT(_, UXK_MINOR))
