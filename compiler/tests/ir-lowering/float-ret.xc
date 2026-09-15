// float-ret — exercises the float RETURN ABI on both backends.
// `pi` returns a float by value (xt6502: $B0-$B4 mailbox; arm64:
// native s0); `run` harvests the float Call result and truncates
// to an i16 global. No float PARAMS (those stay gated). pi()=3.25
// -> (i16)3.
float pi(void)
    {
    return 3.25;
    }

i16 gN;

void run(void)
    {
    gN = (i16)pi();
    }
