// C11 atomics from four threads: read-modify-writes of every width, a spin
// lock from atomic_flag, compare-exchanges (a pointer's too), and the
// orderings and fences. Must print what clang's build prints.
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>

static _Atomic int counter;
static _Atomic long total;
static _Atomic unsigned char bytes;
static _Atomic short halves;
static atomic_flag flag = ATOMIC_FLAG_INIT;
static _Atomic(int*) ptr;
static int locked;

static void* work(void* arg) {
  long k = (long)arg;
  for (int i = 0; i < 100000; i++) {
    atomic_fetch_add(&counter, 1);
    atomic_fetch_add_explicit(&total, k, memory_order_relaxed);
    atomic_fetch_add(&bytes, 1);
    atomic_fetch_sub(&halves, 1);
    while (atomic_flag_test_and_set_explicit(&flag, memory_order_acquire)) {
    }
    locked++;
    atomic_flag_clear_explicit(&flag, memory_order_release);
  }
  return 0;
}

int main(void) {
  pthread_t t[4];
  for (long i = 0; i < 4; i++) pthread_create(&t[i], 0, work, (void*)(i + 1));
  for (int i = 0; i < 4; i++) pthread_join(t[i], 0);
  int e = 400000;
  int ok1 = atomic_compare_exchange_strong(&counter, &e, 7);
  int e2 = 1;
  int ok2 = atomic_compare_exchange_strong(&counter, &e2, 9);
  static int x, y;
  int* old = atomic_exchange(&ptr, &x);
  int* e3 = &x;
  int ok3 = atomic_compare_exchange_weak(&ptr, &e3, &y);
  while (!ok3 && e3 == &x) ok3 = atomic_compare_exchange_weak(&ptr, &e3, &y);
  unsigned o = atomic_fetch_or(&counter, 0x30);
  o += atomic_fetch_and(&counter, 0xff);
  o += atomic_fetch_xor(&counter, 5);
  atomic_thread_fence(memory_order_seq_cst);
  atomic_signal_fence(memory_order_seq_cst);
  atomic_store_explicit(&total, atomic_load_explicit(&total, memory_order_acquire) + 1, memory_order_release);
  atomic_store(&halves, (short)(atomic_load_explicit(&halves, memory_order_relaxed) - 1));
  unsigned char b = atomic_exchange(&bytes, 200);
  printf("%d %d %d %d %d %ld %d %d %d %d %u %d %d\n", atomic_load(&counter), ok1, e, ok2, e2,
         atomic_load(&total), (int)b, (int)atomic_load(&halves), locked, old == 0, o,
         ok3 && atomic_load(&ptr) == &y, (int)atomic_load(&bytes));
  return 0;
}
