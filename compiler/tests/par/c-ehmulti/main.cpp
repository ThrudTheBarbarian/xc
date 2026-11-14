// Two C++ files, each throwing and catching in its own functions: every
// object's frame table must reach the unwinder, not the first object's alone.
#include <cstdio>
#include <stdexcept>
#include <string>

std::string other(int n);   // other.cpp: throws for odd n, catches it itself

static std::string mine(int n)
{
    try {
        if (n % 3 == 0) throw std::runtime_error("three");
        return "m" + std::to_string(n);
    } catch (const std::exception& e) {
        return std::string("c-") + e.what();
    }
}

int main()
{
    std::string out;
    for (int i = 1; i <= 6; i++) out += mine(i) + "," + other(i) + ";";
    try {
        other(-1);   // other.cpp lets a negative n escape
    } catch (const std::invalid_argument& e) {
        out += std::string("escaped-") + e.what();
    }
    std::printf("%s\n", out.c_str());
    return 0;
}
