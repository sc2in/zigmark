const std = @import("std");

/// Fallback mermaid renderer used when pozeiden is not available.
/// Always returns error.MermaidUnavailable so callers degrade to a code block.
pub fn render(_: std.mem.Allocator, _: []const u8) anyerror![]const u8 {
    return error.MermaidUnavailable;
}
