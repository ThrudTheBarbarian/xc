// bit_ops — shifts and bitwise logic over an array. See bit_ops.xc.

@main
struct BitOps {
    static func main() {
        let n = 4096
        let seed = UInt32(CommandLine.arguments.count)
        var a = [UInt32](repeating: 0, count: n)
        for i in 0..<n { a[i] = (UInt32(i) &* 2654435761) &+ seed }
        var acc: UInt32 = 0
        let t0 = bench_now_us()
        for r in 0..<UInt32(600_000) {
            for i in 0..<n {
                // C precedence: + binds tighter than ^, so this is (acc + (...)) ^ mask.
                acc = (acc &+ (((a[i] &+ r) &<< 3) | ((a[i] &+ r) &>> 5))) ^ 0x0F0F_0F0F
            }
        }
        let t1 = bench_now_us()
        print("\(acc) \(t1 - t0)")
    }
}
