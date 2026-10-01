// sort_small — insertion sort of a small array, repeatedly. See sort_small.xc.

@main
struct SortSmall {
    static func main() {
        let n = 64
        let seed = UInt32(CommandLine.arguments.count)
        var a = [UInt32](repeating: 0, count: n)
        var acc: UInt32 = 0
        let t0 = bench_now_us()
        for r in 0..<UInt32(3_200_000) {
            for i in 0..<n {
                a[i] = ((UInt32(i) &* 2654435761) ^ (r &* 40503)) &+ seed
            }
            for i in 1..<n {
                let v = a[i]
                var j = i
                while j > 0 && a[j - 1] > v {
                    a[j] = a[j - 1]
                    j = j - 1
                }
                a[j] = v
            }
            acc = acc &+ a[0] &+ a[n - 1]
        }
        let t1 = bench_now_us()
        print("\(acc) \(t1 - t0)")
    }
}
