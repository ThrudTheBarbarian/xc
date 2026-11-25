// C++ atomics from four std::threads: std::atomic of several widths with
// every memory order, a compare_exchange_weak loop, an atomic<bool> spin
// lock, and shared_ptr copies (their counts are atomic read-modify-writes).
// Must print what clang's build prints.
#include <atomic>
#include <cstdio>
#include <memory>
#include <thread>
#include <vector>

static std::atomic<int> hits{0};
static std::atomic<long long> sum{0};
static std::atomic<unsigned short> wraps{0};
static std::atomic<signed char> down{0};
static std::atomic<bool> busy{false};
static std::atomic<unsigned> maxSeen{0};
static long guarded = 0;

static void raiseMax(unsigned v) {
  unsigned cur = maxSeen.load(std::memory_order_relaxed);
  while (cur < v && !maxSeen.compare_exchange_weak(cur, v, std::memory_order_acq_rel, std::memory_order_relaxed)) {
  }
}

static long work(int k, std::shared_ptr<std::vector<int>> data) {
  long local = 0;
  for (int i = 0; i < 50000; i++) {
    hits.fetch_add(1, std::memory_order_relaxed);
    sum.fetch_add(k, std::memory_order_acq_rel);
    wraps.fetch_add(3);
    down.fetch_sub(1, std::memory_order_release);
    while (busy.exchange(true, std::memory_order_acquire)) {
    }
    guarded += k;
    busy.store(false, std::memory_order_release);
    raiseMax((unsigned)(i * k));
    std::shared_ptr<std::vector<int>> copy = data;
    local += (*copy)[i % copy->size()];
  }
  return local;
}

int main() {
  auto data = std::make_shared<std::vector<int>>(std::vector<int>{1, 2, 3, 4, 5});
  std::vector<std::thread> ts;
  std::vector<long> out(4);
  for (int t = 0; t < 4; t++) ts.emplace_back([t, data, &out] { out[t] = work(t + 1, data); });
  for (auto& t : ts) t.join();
  int expect = 200000;
  bool ok = hits.compare_exchange_strong(expect, 1);
  std::atomic_thread_fence(std::memory_order_seq_cst);
  std::printf("%d %d %lld %u %d %ld %u %ld %ld %ld %ld %ld\n", hits.load(), ok, sum.load(std::memory_order_acquire),
              (unsigned)wraps.load(), (int)down.load(std::memory_order_relaxed), guarded, maxSeen.load(),
              out[0], out[1], out[2], out[3], data.use_count());
}
