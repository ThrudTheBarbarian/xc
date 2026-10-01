// arc_array — hold objects in an array and walk them. See arc_array.xc.

final class Cell {
    let v: UInt32
    init(_ x: UInt32) { v = x }
    func get() -> UInt32 { v }
}

@main
struct ArcArray {
    static func main() {
        let n = 1024
        let seed = UInt32(CommandLine.arguments.count)
        var cells: [Cell] = []
        cells.reserveCapacity(n)
        for i in 0..<n { cells.append(Cell(UInt32(i) &+ seed)) }
        var acc: UInt32 = 0
        let t0 = bench_now_us()
        for _ in 0..<UInt32(3_000_000) {
            for i in 0..<n { acc = acc &+ cells[i].get() }
        }
        let t1 = bench_now_us()
        print("\(acc) \(t1 - t0)")
    }
}
