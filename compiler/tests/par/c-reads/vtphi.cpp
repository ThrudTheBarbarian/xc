// vtphi.cpp — a throw of one of two exception types, chosen by a branch:
// clang -O1 joins the two vtable addresses in a phi of constant
// expressions (`getelementptr inbounds inrange(-16, 24) (i8, ptr @vtable,
// i64 16)`), which xcc reads (tests/par/c-reads.sh).
#include <cstdio>
#include <stdexcept>

static int nested(int k)
{
    try {
        try {
            if (k % 2)
                throw std::out_of_range("odd");
            throw std::invalid_argument("even");
        } catch (const std::out_of_range&) {
            throw;
        }
    } catch (const std::logic_error& e) {
        return e.what()[0];
    }
    return 0;
}

int main()
{
    int s = 0;
    for (int k = 0; k < 10; k++)
        s += nested(k);
    std::printf("%d\n", s);
    return 0;
}
