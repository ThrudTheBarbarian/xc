#include <cstdio>
#include <thread>
struct S { const char* n; S(const char* s) : n(s) {} ~S() { std::printf("~%s\n", n); } };
static S st{"static"};
thread_local S a{"a"};
thread_local S b{"b"};
static void use(const char* who) { S& x = a; S& y = b; std::printf("%s %s %s\n", who, x.n, y.n); }
int main() {
  std::thread t([] { use("thread"); });
  t.join();
  std::printf("joined\n");
  use("main");
}
