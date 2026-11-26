// Small structs passed by value, which clang gives arm64 as [2 x i64]
// arguments: a std::span and a std::string_view, to functions xcc reads,
// called plainly and in a try (an invoke). x86-64 passes each as two
// scalar arguments, so there it checks nothing new.
#include <cstdio>
#include <span>
#include <stdexcept>
#include <string_view>

__attribute__((noinline)) long spanSum(std::span<const int> s)
{
    long t = 0;
    for (int v : s)
        t += v;
    return t;
}

__attribute__((noinline)) long countChar(std::string_view sv, char c)
{
    if (sv.empty())
        throw std::invalid_argument("empty");
    long n = 0;
    for (char x : sv)
        n += x == c;
    return n;
}

int main(int argc, char**)
{
    static int data[64];
    for (int i = 0; i < 64; i++)
        data[i] = i * argc - 7;
    long s = 0;
    for (int k = 1; k <= 64; k += 9)
        s += spanSum(std::span<const int>(data, k));
    const char* words[] = {"banana", "", "abracadabra", "aa"};
    long c = 0;
    for (int i = 0; i < 4; i++) {
        try {
            c += countChar(std::string_view(words[i]), 'a') * 10;
        } catch (const std::invalid_argument&) {
            c += 1;
        }
    }
    std::printf("%ld %ld\n", s, c);
    return 0;
}
