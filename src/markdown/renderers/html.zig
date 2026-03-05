const std = @import("std");
const Array = std.ArrayList;
const Allocator = std.mem.Allocator;
const tst = std.testing;
const math = std.math;
const mem = std.mem;

const mecha = @import("mecha");

const AST = @import("../ast.zig");
const Parser = @import("../parser.zig");
const tokens = @import("../tokens.zig");
const Token = tokens.Token;
const Range = tokens.Range;

/// Enhanced HTML renderer with support for all in_line elements
pub fn render(allocator: std.mem.Allocator, doc: AST.Document) ![]u8 {
    var buf = std.ArrayList(u8){};
    var writer = buf.writer(allocator);

    for (doc.children.items) |child| {
        switch (child) {
            .heading => |h| {
                try writer.print("<h{d}>", .{h.level});
                for (h.children.items) |in_line_elem| {
                    try renderInlineHtml(writer, in_line_elem);
                }
                try writer.print("</h{d}>", .{h.level});
            },
            .paragraph => |p| {
                try writer.writeAll("<p>");
                for (p.children.items) |in_line_elem| {
                    try renderInlineHtml(writer, in_line_elem);
                }
                try writer.writeAll("</p>");
            },
            .blockquote => |bq| {
                try writer.writeAll("<blockquote>");
                for (bq.children.items) |block| {
                    switch (block) {
                        .paragraph => |p| {
                            try writer.writeAll("<pre>");
                            for (p.children.items) |in_line_elem| {
                                try renderInlineHtml(writer, in_line_elem);
                            }
                            try writer.writeAll("</pre>");
                        },
                        else => {},
                    }
                }
                try writer.writeAll("</blockquote>");
            },
            .list => |lst| {
                switch (lst.type) {
                    .unordered => try writer.writeAll("<ul>"),
                    .ordered => try writer.writeAll("<ol>"),
                }
                for (lst.items.items) |item| {
                    try writer.writeAll("<li>");
                    for (item.children.items) |block| {
                        switch (block) {
                            .paragraph => |p| {
                                for (p.children.items) |in_line_elem| {
                                    try renderInlineHtml(writer, in_line_elem);
                                }
                            },
                            else => {},
                        }
                    }
                    try writer.writeAll("</li>");
                }
                switch (lst.type) {
                    .unordered => try writer.writeAll("</ul>"),
                    .ordered => try writer.writeAll("</ol>"),
                }
            },
            .footnote_definition => |fn_def| {
                try writer.print("<div class=\"footnote\" id=\"fn:{s}\">", .{fn_def.label});
                for (fn_def.children.items) |block| {
                    switch (block) {
                        .paragraph => |p| {
                            try writer.print("<p><b>{s}</b>:", .{fn_def.label});
                            for (p.children.items) |in_line_elem| {
                                try renderInlineHtml(writer, in_line_elem);
                            }
                            try writer.writeAll("</p>");
                        },
                        else => {},
                    }
                }
                try writer.writeAll("</div>");
            },
            else => {},
        }
    }

    return buf.toOwnedSlice(allocator);
}

fn renderInlineHtml(writer: anytype, in_line_elem: AST.Inline) !void {
    switch (in_line_elem) {
        .text => |t| {
            try writer.writeAll(t.content);
        },
        .emphasis => |e| {
            try writer.writeAll("<em>");
            for (e.children.items) |child| {
                try renderInlineHtml(writer, child);
            }
            try writer.writeAll("</em>");
        },
        .strong => |s| {
            try writer.writeAll("<strong>");
            for (s.children.items) |child| {
                try renderInlineHtml(writer, child);
            }
            try writer.writeAll("</strong>");
        },
        .link => |l| {
            try writer.print("<a href=\"{s}\">", .{l.destination.url});
            for (l.children.items) |child| {
                try renderInlineHtml(writer, child);
            }
            try writer.writeAll("</a>");
        },
        .footnote_reference => |fr| {
            try writer.print("<a href=\"#fn:{s}\" class=\"footnote-ref\">{s}</a>", .{ fr.label, fr.label });
        },
        else => {},
    }
}

fn ok(s: []const u8, expected: []const u8) !void {
    var parser = Parser.init();
    defer parser.deinit(tst.allocator);
    var res = try parser.parseMarkdown(tst.allocator, s);
    defer res.deinit(tst.allocator);
    errdefer res.deinit(tst.allocator);

    const out = try render(tst.allocator, res);
    defer tst.allocator.free(out);

    try tst.expectEqualStrings(expected, out);
}

test "heading" {
    try ok("# Heading", "<h1>Heading</h1>");
    try ok("## Level 2", "<h2>Level 2</h2>");
    try ok("### Level 3", "<h3>Level 3</h3>");
}
