const std = @import("std");
const testing = std.testing;
const lex = @import("lexer.zig");
const parser = @import("parser.zig");

export fn cmain() void {
    main() catch unreachable;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    var allocator = gpa.allocator();

    var stdin_buffer: [1024]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
    const stdin = &stdin_reader.interface;
    const data = try stdin.readAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(data);

    const lexer = parser.Lexer{ .real = try lex.Lexer.init(allocator, data) };
    var p = try parser.Parser.init(allocator, lexer);
    defer p.deinit();

    var table = p.parse() catch |err| {
        std.debug.print("error parsing {}\n", .{err});
        std.debug.print("{?}\n", .{p.diag});
        return;
    };
    defer table.deinit(allocator);
}
