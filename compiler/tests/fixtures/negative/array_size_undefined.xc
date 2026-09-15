// Array size that references an undeclared identifier used to
// silently resolve to zero, emitting a zero-byte backing block
// and letting the program scribble into whatever followed it in
// memory. Parser now rejects any non-literal size expression so
// typos and missing #defines surface before the first codegen
// byte.
// xtc: error "Array size must be a compile-time integer literal"

bool flags[sizep];    // sizep never declared — was silently 0

void main(void) { flags[0] = true; }
