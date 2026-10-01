// branch_mix — data-dependent branches over an array. See branch_mix.xc.

@main
struct BranchMix {
    static func main() {
        let n = 4096
        let seed = UInt32(CommandLine.arguments.count)
        var a = [UInt32](repeating: 0, count: n)
        for i in 0..<n { a[i] = (UInt32(i) &* 2654435761) &+ seed }
        var acc: UInt32 = 0
        let t0 = bench_now_us()
        for _ in 0..<UInt32(500_000) {
            for i in 0..<n {
                if (a[i] & 1) == 0 { acc = acc &+ a[i] } else { acc = acc ^ a[i] }
            }
        }
        let t1 = bench_now_us()
        print("\(acc) \(t1 - t0)")
    }
}
