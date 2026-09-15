# Warning fixtures

Each `.xc` here carries an expectation as a leading comment:

    //xtc-warn: <substring that must appear on stderr>

One per line; every one must be present. A fixture with none asserts SILENCE:
the compiler must warn about nothing in it, so a false positive is caught
rather than accumulating.

The harness is `selfhost/tools/warn-diff.sh`. Nothing else in the tree compares
diagnostics, so without it a sema rule present in one compiler and missing from
the other would pass every differential test.
