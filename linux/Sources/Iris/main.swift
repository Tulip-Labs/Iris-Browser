import Foundation

// Iris for Linux: Swift, libadwaita (through swift-adwaita) and WebKitGTK.
// iris --shield-rules LEVEL LISTS OUT: the content rules a level makes from
// the lists in LISTS (named as Iris keeps them), written to OUT (for checks)
if CommandLine.arguments.count == 5 && CommandLine.arguments[1] == "--shield-rules",
   let level = ShieldLevel(rawValue: CommandLine.arguments[2]) {
    let t0 = Date()
    var c = ShieldConverter(level: level)
    for l in level.lists {
        if let t = try? String(contentsOfFile: CommandLine.arguments[3] + "/\(l.rawValue).txt", encoding: .utf8) { c.add(list: t) }
    }
    let (b, h, e) = (c.blocks.count, c.hides.count, c.exceptions.count)
    let parts = c.finish()
    for (i, p) in parts.enumerated() { try? p.write(toFile: CommandLine.arguments[4] + "/\(level.rawValue)-\(i).json", atomically: true, encoding: .utf8) }
    print("\(level.rawValue): \(b) blocks, \(h) hiding rules, \(e) exceptions, \(parts.count) parts, \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
    exit(0)
}
Engine.videoEnvironment()
let iris = IrisApp()
exit(Int32(iris.run()))
