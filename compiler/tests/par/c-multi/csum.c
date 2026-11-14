/* The C part: a static helper of the same name again, and a loop xcc lifts. */
static long scale(long x) { return x - 2; }
long cSum(const long* a, long n)
{
    long s = 0;
    for (long i = 0; i < n; i++)
        s += scale(a[i]);
    return s;
}
