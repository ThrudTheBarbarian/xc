// int_accum — integer add and xor over an array. See int_accum.xc.

@main
struct IntAccum {
    static func main() {
        let n = 4096
        let seed = UInt32(CommandLine.arguments.count)
        var a = [UInt32](repeating: 0, count: n)
        for i in 0..<n { a[i] = (UInt32(i) &* 2654435761) &+ seed }
        var acc: UInt32 = 0
        let t0 = bench_now_us()
        for _ in 0..<UInt32(600_000) {
            for i in 0..<n { acc = acc &+ (a[i] ^ acc) }
        }
        let t1 = bench_now_us()
        print("\(acc) \(t1 - t0)")
    }
}
