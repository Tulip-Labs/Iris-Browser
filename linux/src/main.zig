//! Iris for Linux: Zig, libadwaita and WPE WebKit, through their C headers.
const std = @import("std");
const core = @import("core.zig");
const rules = @import("rules.zig");
const engine = @import("engine.zig");
const App = @import("app.zig").App;

/// iris --shield-rules LEVEL LISTS OUT: the content rules a level makes from
/// the lists in LISTS (named as Iris keeps them), written to OUT (for checks)
fn shieldRules(args: []const [:0]u8) u8 {
    const level = std.meta.stringToEnum(rules.Level, args[2]) orelse return 2;
    const t0 = std.time.milliTimestamp();
    var arena = std.heap.ArenaAllocator.init(core.gpa);
    var conv = rules.Converter.init(arena.allocator(), level);
    for (level.lists()) |l| {
        const p = std.fmt.allocPrint(core.gpa, "{s}/{s}.txt", .{ args[3], l.id() }) catch return 1;
        defer core.gpa.free(p);
        const text = std.fs.cwd().readFileAlloc(core.gpa, p, 64 << 20) catch continue;
        defer core.gpa.free(text);
        conv.addList(text);
    }
    const counts = .{ conv.blocks.items.len, conv.hides.items.len, conv.exceptions.items.len };
    const parts = conv.finish(120_000);
    for (parts, 0..) |part, i| {
        const p = std.fmt.allocPrint(core.gpa, "{s}/{s}-{d}.json", .{ args[4], @tagName(level), i }) catch return 1;
        defer core.gpa.free(p);
        std.fs.cwd().writeFile(.{ .sub_path = p, .data = part }) catch return 1;
    }
    const secs = @as(f64, @floatFromInt(std.time.milliTimestamp() - t0)) / 1000;
    std.debug.print("{s}: {d} blocks, {d} hiding rules, {d} exceptions, {d} parts, {d:.1} s\n", .{ @tagName(level), counts[0], counts[1], counts[2], parts.len, secs });
    return 0;
}

pub fn main() u8 {
    const args = std.process.argsAlloc(core.gpa) catch return 1;
    defer std.process.argsFree(core.gpa, args);
    if (args.len == 5 and std.mem.eql(u8, args[1], "--shield-rules")) return shieldRules(args);
    engine.Engine.videoEnvironment();
    return App.create().run();
}
