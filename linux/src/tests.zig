const std = @import("std");
test {
    _ = @import("core.zig");
    _ = @import("search.zig");
    _ = @import("rules.zig");
    _ = @import("shields.zig");
    _ = @import("updates.zig");
}
// every public function of the program is compiled, even ones no test runs
test "everything compiles" {
    std.testing.refAllDeclsRecursive(@import("app.zig"));
    std.testing.refAllDeclsRecursive(@import("browser.zig"));
    std.testing.refAllDeclsRecursive(@import("overlays.zig"));
    std.testing.refAllDeclsRecursive(@import("keys.zig"));
    std.testing.refAllDeclsRecursive(@import("tab.zig"));
    std.testing.refAllDeclsRecursive(@import("engine.zig"));
    std.testing.refAllDeclsRecursive(@import("stage.zig"));
    std.testing.refAllDeclsRecursive(@import("webview.zig"));
    std.testing.refAllDeclsRecursive(@import("glass.zig"));
    std.testing.refAllDeclsRecursive(@import("ui.zig"));
    std.testing.refAllDeclsRecursive(@import("store.zig"));
    std.testing.refAllDeclsRecursive(@import("main.zig"));
}
