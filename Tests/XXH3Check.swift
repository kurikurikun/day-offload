// Checks XXH3.swift against reference vectors: ./Tests/run.sh
import Foundation

@main
enum XXH3Check {
    static func main() throws {
        let text = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        let cases = text.split(separator: "\n").filter { !$0.hasPrefix("#") }.map { $0.split(separator: " ") }
        let n = cases.compactMap { Int($0[0]) }.max() ?? 0
        var x: UInt64 = 0
        var data = [UInt8](repeating: 0, count: n)
        for i in 0..<n { x = x &* 6364136223846793005 &+ 1442695040888963407; data[i] = UInt8(x >> 56) }
        var failures = 0
        var rng = SystemRandomNumberGenerator()
        for c in cases {
            let len = Int(c[0])!, want = String(c[1])
            var one = XXH3_128(); one.update(Array(data[0..<len]))
            var streamed = XXH3_128(); var i = 0
            while i < len { let k = min(len - i, Int.random(in: 1...70_000, using: &rng)); streamed.update(Array(data[i..<i + k])); i += k }
            if one.hexDigest != want || streamed.hexDigest != want {
                failures += 1; print("FAIL len \(len): got \(one.hexDigest) / \(streamed.hexDigest), want \(want)")
            }
        }
        print(failures == 0 ? "xxh3: all \(cases.count) vectors match" : "xxh3: \(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
