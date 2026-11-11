// Strings and characters: building, case changes in a loop, searching,
// counting, conversions to and from numbers, a character table.
#include <cstdio>
#include <string>
#include <cctype>
#include <cstring>

static void upper(char* s, size_t n) { for (size_t i = 0; i < n; i++) if (s[i] >= 'a' && s[i] <= 'z') s[i] = (char)(s[i] - 32); }
static unsigned hash(const char* s, size_t n) { unsigned h = 2166136261u; for (size_t i = 0; i < n; i++) { h ^= (unsigned char)s[i]; h *= 16777619u; } return h; }
static int classes(const std::string& s) { int n = 0; for (char c : s) n += std::isdigit((unsigned char)c) ? 3 : std::isspace((unsigned char)c) ? 2 : 1; return n; }

int main()
    {
    std::string s;
    for (int i = 0; i < 400; i++) { s += std::to_string(i * 17 % 1000); s += (i % 5 == 0) ? ' ' : (char)('a' + i % 26); }
    std::string t = s;
    upper(t.data(), t.size());
    unsigned h1 = hash(s.data(), s.size()), h2 = hash(t.data(), t.size());
    size_t pos = t.find("Z1"), last = t.rfind('7');
    long nums = 0;
    for (size_t i = 0; i + 3 <= s.size(); i += 37) nums += std::strtol(s.substr(i, 3).c_str(), nullptr, 10);
    int table[256] = {0};
    for (unsigned char c : s) table[c]++;
    int spaces = table[(unsigned char)' '];
    std::printf("%zu %u %u %zu %zu %ld %d %d\n", s.size(), h1, h2, pos, last, nums, spaces, classes(s));
    return 0;
    }
