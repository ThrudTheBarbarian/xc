// sieve — sieve of Eratosthenes over a fixed range, repeatedly. See sieve.xc.

@main
struct Sieve {
    static func main() {
        let n = 8192
        let seed = UInt32(CommandLine.arguments.count)
        var flags = [UInt8](repeating: 0, count: n)
        var acc: UInt32 = 0
        let t0 = bench_now_us()
        for r in 0..<UInt32(150_000) {
            for i in 0..<n { flags[i] = 1 }
            var count: UInt32 = 0
            for i in 2..<n where flags[i] != 0 {
                count = count &+ 1
                var j = i + i
                while j < n {
                    flags[j] = 0
                    j = j + i
                }
            }
            acc = acc &+ count &+ (r & seed)
        }
        let t1 = bench_now_us()
        print("\(acc) \(t1 - t0)")
    }
}
