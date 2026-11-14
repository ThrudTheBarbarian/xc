/* A C function xcc compiles, between a C++ throw (cb, in thrower.cpp) and
   its catch: enough live values that it saves callee-saved registers. */
long cb(long);
long apply(long n)
{
    /* Enough live values that xcc saves and uses callee-saved registers. */
    long a = n, b = n * 2, c = n * 3, d = n * 5, e = n * 7, g = n * 11, h = n * 13, k = n * 17, s = 0;
    for (long i = 0; i < n; i++) {
        s += cb(i) + a + b;
        a = a * 3 + c; b = b * 5 + d; c = c ^ e; d = d + g; e = e - h; g = g * 7 + k; h = h + i; k = k ^ s;
    }
    return s + a + b + c + d + e + g + h + k;
}
