#include <cstdio>
#include <string>
#include <thread>
#include <vector>
static int live = 0;
struct Counter { std::string name; long n = 0; Counter() : name("c") { __atomic_add_fetch(&live, 1, __ATOMIC_SEQ_CST); } ~Counter() { __atomic_sub_fetch(&live, 1, __ATOMIC_SEQ_CST); } };
thread_local Counter tc;
thread_local long tl[8] = {1, 2, 3, 4, 5, 6, 7, 8};
long work(int k) { for (int i = 0; i < 1000; i++) { tc.n += k; tl[i & 7] += k; } long s = tc.n; for (long v : tl) s += v; return s + (long)tc.name.size(); }
int main() { std::vector<long> r(4); std::vector<std::thread> ts;
  for (int i = 0; i < 4; i++) ts.emplace_back([&r, i] { r[i] = work(i + 1); });
  for (auto& t : ts) t.join();
  std::printf("%ld %ld %ld %ld main %ld %ld live %d\n", r[0], r[1], r[2], r[3], tc.n, tl[0] + tl[7], live); }
