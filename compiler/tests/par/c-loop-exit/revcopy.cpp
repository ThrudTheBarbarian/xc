// A vector built from reverse iterators, then reversed: the copy loop's
// end pointer is used two blocks past the loop (std::reverse's end), where
// it must be the end, not the last element's address.
#include <algorithm>
#include <cstdio>
#include <numeric>
#include <vector>

int main(int argc, char**)
{
    std::vector<int> v(2400);
    std::iota(v.begin(), v.end(), -1200 + argc);
    std::vector<int> w(v.rbegin(), v.rbegin() + 50);
    std::reverse(w.begin(), w.end());
    long ws = std::accumulate(w.begin(), w.end(), 0L);
    std::printf("%ld %d %d %zu\n", ws, w.front(), w.back(), w.size());
    return 0;
}
