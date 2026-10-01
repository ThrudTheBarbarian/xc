// int_muldiv — integer multiply and divide by constants. See int_muldiv.xc.

@main
struct IntMulDiv {
    static func main() {
        let n = 1024
        let seed = UInt32(CommandLine.arguments.count)
        var a = [UInt32](repeating: 0, count: n)
        for i in 0..<n { a[i] = (UInt32(i) &* 2654435761) &+ seed }
        var acc: UInt32 = 0
        let t0 = bench_now_us()
        for _ in 0..<UInt32(6_800_000) {
            for i in 0..<n { acc = acc &+ ((a[i] &* 7) / 3) &+ (a[i] / 11) }
        }
        let t1 = bench_now_us()
        print("\(acc) \(t1 - t0)")
    }
}
