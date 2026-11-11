// The containers: vector, deque, list, map, unordered_map, set, string,
// array and pair, filled and walked in loops.
#include <cstdio>
#include <vector>
#include <deque>
#include <list>
#include <map>
#include <unordered_map>
#include <set>
#include <string>
#include <array>

int main()
    {
    std::vector<int> v;
    for (int i = 0; i < 3000; i++) v.push_back((i * 37) % 1009);
    std::deque<int> dq;
    for (int i = 0; i < 500; i++) { if (i & 1) dq.push_front(i); else dq.push_back(i); }
    std::list<double> li;
    for (int i = 0; i < 300; i++) li.push_back(i * 0.25);
    std::map<int, int> m;
    for (int x : v) m[x % 50] += x;
    std::unordered_map<int, long> um;
    for (size_t i = 0; i < v.size(); i++) um[v[i] % 17] += (long)i;
    std::set<int> st(v.begin(), v.end());
    std::array<long, 64> ar{};
    for (size_t i = 0; i < ar.size(); i++) ar[i] = (long)(i * i);
    std::string s;
    for (int i = 0; i < 200; i++) s += (char)('a' + i % 26);
    long vs = 0; for (int x : v) vs += x;
    long ds = 0; for (size_t i = 0; i < dq.size(); i++) ds += dq[i] * (long)(i % 7);
    double ls = 0; for (double x : li) ls += x;
    long ms = 0; for (auto& [k, val] : m) ms += k * (long)val;
    long us = 0; for (int k = 0; k < 17; k++) us += um[k] * k;
    long as = 0; for (long x : ar) as += x;
    int cs = 0; for (char c : s) cs += c;
    std::pair<int, double> p{(int)st.size(), ls};
    std::printf("%ld %ld %.2f %ld %ld %ld %d %d %.2f %zu\n", vs, ds, ls, ms, us, as, cs, p.first, p.second, s.find("xyz"));
    return 0;
    }
