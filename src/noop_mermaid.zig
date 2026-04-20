const std = @import("std");

/// Stand-in for the pozeiden mermaid renderer used when the pozeiden
/// dependency is not available. Always returns an error so callers fall
/// back to rendering the raw fenced code block.
pub fn render(_: std.mem.Allocator, _: []const u8) anyerror![]const u8 {
    return error.MermaidUnavailable;
}
