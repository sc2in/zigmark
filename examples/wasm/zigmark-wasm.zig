//! zigmark WASM entry point
//!
//! Build with:
//!   zig build wasm
//!
//! Outputs land in zig-out/wasm/:
//!   zigmark.wasm   — the WASM module
//!   index.html     — live preview demo
//!
//! Serve it:
//!   cd zig-out/wasm && python3 -m http.server 8080

const std = @import("std");

const zigmark = @import("zigmark");
const pozeiden = @import("pozeiden");

// ── Allocator ────────────────────────────────────────────────────────────────
// Use a fixed-buffer allocator backed by WASM linear memory.
// 4 MiB is generous for most documents; the page allocator grows as needed.
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

// ── Persistent state ─────────────────────────────────────────────────────────
// Keep the last render result alive so JS can read from the pointer.
var last_result: ?[]u8 = null;

fn freeLastResult() void {
    if (last_result) |buf| {
        allocator.free(buf);
        last_result = null;
    }
}

// ── Exported API ─────────────────────────────────────────────────────────────

/// Parse Markdown and render to HTML, with Mermaid diagrams rendered to SVG.
/// `input` is a pointer into WASM linear memory; `len` is the byte length.
/// Returns a pointer to the result, or 0 on error.
/// The pointer is valid until the next call to any render function.
export fn render_html(input: [*]const u8, len: usize) usize {
    freeLastResult();
    const slice = input[0..len];
    var parser = zigmark.Parser.init();
    var doc = parser.parseMarkdown(allocator, slice) catch return 0;
    defer doc.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    zigmark.renderHtmlWithMermaid(allocator, &aw.writer, doc, pozeiden.render) catch return 0;
    const buf = aw.toOwnedSlice() catch return 0;
    last_result = buf;
    return @intFromPtr(buf.ptr);
}

/// Parse Markdown and render to a human-readable AST tree.
export fn render_ast(input: [*]const u8, len: usize) usize {
    return renderWith(input, len, zigmark.ASTRenderer);
}

/// Parse Markdown and render to a token-efficient AI representation.
export fn render_ai(input: [*]const u8, len: usize) usize {
    return renderWith(input, len, zigmark.AIRenderer);
}

/// Return the length (excluding NUL) of the last render result.
export fn result_len() usize {
    return if (last_result) |buf| buf.len else 0;
}

/// Allocate `len` bytes in WASM memory and return the pointer.
/// JS uses this to write the Markdown source before calling render_*.
export fn alloc_buf(len: usize) usize {
    const buf = allocator.alloc(u8, len) catch return 0;
    return @intFromPtr(buf.ptr);
}

/// Free a buffer previously returned by `alloc_buf`.
export fn free_buf(ptr: usize, len: usize) void {
    if (ptr == 0) return;
    const slice: [*]u8 = @ptrFromInt(ptr);
    allocator.free(slice[0..len]);
}

/// Return the library version as a pointer to a static string.
export fn version_ptr() usize {
    return @intFromPtr(zigmark.version.ptr);
}

/// Return the length of the version string.
export fn version_len() usize {
    return zigmark.version.len;
}

// ── Internal ─────────────────────────────────────────────────────────────────

fn renderWith(input: [*]const u8, len: usize, renderer: zigmark.Renderer) usize {
    freeLastResult();

    const slice = input[0..len];
    var parser = zigmark.Parser.init();
    var doc = parser.parseMarkdown(allocator, slice) catch return 0;
    defer doc.deinit(allocator);

    const buf = renderer.render(allocator, doc) catch return 0;
    last_result = buf;
    return @intFromPtr(buf.ptr);
}
