// matrix_mul — multiply two small square matrices, repeatedly. See matrix_mul.xc.

@main
struct MatrixMul {
    static func main() {
        let m = 32
        let seed = UInt32(CommandLine.arguments.count)
        var a = [UInt32](repeating: 0, count: m * m)
        var b = [UInt32](repeating: 0, count: m * m)
        var c = [UInt32](repeating: 0, count: m * m)
        for i in 0..<(m * m) {
            a[i] = (UInt32(i) &+ seed) & 15
            b[i] = (UInt32(i) ^ seed) & 15
        }
        let t0 = bench_now_us()
        for r in 0..<UInt32(180_000) {
            for i in 0..<m {
                for j in 0..<m {
                    var s: UInt32 = 0
                    for k in 0..<m { s = s &+ (a[i * m + k] &* b[k * m + j]) }
                    c[i * m + j] = s &+ r
                }
            }
        }
        var acc: UInt32 = 0
        for i in 0..<(m * m) { acc = acc &+ c[i] }
        let t1 = bench_now_us()
        print("\(acc) \(t1 - t0)")
    }
}
