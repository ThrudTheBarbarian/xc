// float_math — float multiply, accumulated in double. See float_math.xc.

@main
struct FloatMath {
    static func main() {
        let n = 4096
        let seed = UInt32(CommandLine.arguments.count)
        var a = [Float](repeating: 0, count: n)
        var b = [Float](repeating: 0, count: n)
        for i in 0..<n {
            a[i] = Float((UInt32(i) &+ seed) % 16)
            b[i] = Float((UInt32(i) % 7) + 1)
        }
        var acc = 0.0
        let t0 = bench_now_us()
        for _ in 0..<UInt32(400_000) {
            for i in 0..<n { acc = acc + Double(a[i] * b[i]) }
        }
        let t1 = bench_now_us()
        // The sum is exact but exceeds UInt32; go through UInt64 and let the
        // narrowing wrap, as float_math.xc does.
        print("\(UInt32(truncatingIfNeeded: UInt64(acc))) \(t1 - t0)")
    }
}
