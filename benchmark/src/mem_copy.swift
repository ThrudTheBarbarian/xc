// mem_copy — copy between arrays element by element. See mem_copy.xc.

@main
struct MemCopy {
    static func main() {
        let n = 4096
        let seed = UInt32(CommandLine.arguments.count)
        var src = [UInt32](repeating: 0, count: n)
        var dst = [UInt32](repeating: 0, count: n)
        for i in 0..<n { src[i] = UInt32(i) &+ seed }
        var acc: UInt32 = 0
        let t0 = bench_now_us()
        for r in 0..<UInt32(6_800_000) {
            for i in 0..<n { dst[i] = src[i] &+ r }
            acc = acc &+ dst[Int(r % UInt32(n))]
        }
        let t1 = bench_now_us()
        print("\(acc) \(t1 - t0)")
    }
}
