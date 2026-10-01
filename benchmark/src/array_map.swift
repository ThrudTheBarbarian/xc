// array_map — elementwise c[i] = a[i] + b[i] * k. See array_map.xc.

@main
struct ArrayMap {
    static func main() {
        let n = 4096
        let seed = UInt32(CommandLine.arguments.count)
        var a = [UInt32](repeating: 0, count: n)
        var b = [UInt32](repeating: 0, count: n)
        var c = [UInt32](repeating: 0, count: n)
        for i in 0..<n {
            a[i] = UInt32(i) &+ seed
            b[i] = (UInt32(i) &* 3) &+ seed
        }
        let t0 = bench_now_us()
        for r in 0..<UInt32(5_000_000) {
            for i in 0..<n { c[i] = a[i] &+ (b[i] &* 7) &+ r }
        }
        var acc: UInt32 = 0
        for i in 0..<n { acc = acc &+ c[i] }
        let t1 = bench_now_us()
        print("\(acc) \(t1 - t0)")
    }
}
