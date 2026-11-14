#include <stdexcept>
#include <string>

static int check(int n)
{
    if (n < 0) throw std::invalid_argument("negative");
    if (n % 2) throw std::out_of_range("odd");
    return n * 10;
}

std::string other(int n)
{
    try {
        return "o" + std::to_string(check(n));
    } catch (const std::out_of_range& e) {
        return std::string("k-") + e.what();
    }
}
