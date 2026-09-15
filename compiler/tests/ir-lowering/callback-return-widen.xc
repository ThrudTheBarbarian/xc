// callback-return-widen — a plain function RETURNED where a callback is
// declared has to WIDEN into the two-word {recv, code} pair, exactly as one
// passed as an argument does.
//
// It did not. The return path ran its own coercion cascade — pointer, float,
// integer — and an aggregate destination matched none of them, so the widened
// function fell through to the INTEGER case: the code address was truncated
// to the aggregate's width and the receiver word was never written. Calling
// the result crashed, at every -O level (private:docs/bugs/075).
//
// The lowering has three sites that can see this conversion: call arguments,
// value contexts, and returns. Two widened. This fixture is the third, and it
// exists because NOTHING IN THE TREE RETURNED ONE — which is why a green
// ir-diff said nothing about it. The self-hosted port coerces returns through
// the same helper it uses for arguments and so was always right; the
// differential could not report the disagreement without a file that had it.
i32 triple(i32 n)
    {
    return n * 3;
    }

callback op i32(i32 n) pick(void)
    {
    return &triple;
    }
