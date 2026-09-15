# UXKit guide examples

Every example that the UXKit guides show in full is a compiling program in this
directory. `run_doc_examples.sh` builds them all.

A documented example should work when someone pastes it. A build catches an
example that goes stale, such as one using a removed `^` sigil or a `weak:`
qualifier that is now a compile error.

If a guide shows a complete program, that program is a file here and the gate
compiles it. Fragments in the prose (a line or two showing a call) stay in the
prose.
