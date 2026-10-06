// matrix_mul_f32 — multiply two float matrices, repeatedly. See matrix_mul_f32.xc.

@main
struct MatrixMulF32 {
    static func main() {
        let m = 128
        let seed = UInt32(CommandLine.arguments.count)
        var a = [Float](repeating: 0, count: m * m)
        var b = [Float](repeating: 0, count: m * m)
        var c = [Float](repeating: 0, count: m * m)
        for i in 0..<(m * m) {
            a[i] = Float((UInt32(i) &+ seed) & 15)
            b[i] = Float((UInt32(i) ^ seed) & 15)
        }
        var acc: UInt32 = 0
        let t0 = bench_now_us()
        for r in 0..<10000 {
            a[r % (m * m)] = Float(UInt32(r) & 15)
            for i in 0..<m {
                for j in 0..<m {
                    var s: Float = 0
                    for k in 0..<m { s = s + a[i * m + k] * b[k * m + j] }
                    c[i * m + j] = s
                }
            }
            acc = acc &+ UInt32(c[(r * 7919) % (m * m)])
        }
        for i in 0..<(m * m) { acc = acc &+ UInt32(c[i]) }
        let t1 = bench_now_us()
        print("\(acc) \(t1 - t0)")
    }
}
