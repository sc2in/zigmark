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

// ── Allocators ────────────────────────────────────────────────────────────────
// page_allocator: baseline — calls memory.grow per allocation group.
const page_alloc = std.heap.page_allocator;

// ArenaAllocator: resets with retain_capacity so pages are reused across calls
// rather than returned to the OS.  All parse and render allocations become
// simple pointer-bump ops after the first call.
var render_arena: std.heap.ArenaAllocator = .init(page_alloc);

// FixedBufferAllocator: zero-syscall bump allocator backed by a static 2 MB
// region.  Fastest possible, but returns error.OutOfMemory for very large docs.
var fba_buf: [2 * 1024 * 1024]u8 = undefined;
var render_fba: std.heap.FixedBufferAllocator = .init(&fba_buf);

// ── Mermaid SVG cache ─────────────────────────────────────────────────────────
// In the live-preview use case, mermaid blocks rarely change between keystrokes
// while the surrounding prose does.  Caching the rendered SVG by (hash, len) of
// the source turns repeated renders into a hash check + memcpy instead of a
// full pozeiden parse-and-layout pass.
//
// Cache is page_alloc-owned so entries survive arena/fba resets.  The caller
// (zigmark HTML renderer) does `defer alloc.free(svg)` so we return a fresh
// `alloc.dupe` on every call — cheap compared to re-rendering.

const MERMAID_CACHE_SLOTS = 8; // covers typical 1–4 diagrams per page with room

const MermaidEntry = struct {
    hash: u64 = 0,
    len: usize = 0, // source byte length — secondary key to reduce collisions
    svg: ?[]const u8 = null, // page_alloc owned; null = empty slot
};

var mermaid_cache: [MERMAID_CACHE_SLOTS]MermaidEntry = [_]MermaidEntry{.{}} ** MERMAID_CACHE_SLOTS;
var mermaid_cache_cursor: usize = 0; // round-robin eviction

fn fnv1a64(data: []const u8) u64 {
    var h: u64 = 14695981039346656037;
    for (data) |b| {
        h ^= @as(u64, b);
        h *%= 1099511628211;
    }
    return h;
}

/// Drop-in replacement for `pozeiden.render` that caches SVG output.
/// Matches the `MermaidRendererFn` signature so it can be passed directly.
fn cachedMermaidRender(alloc: std.mem.Allocator, source: []const u8) anyerror![]const u8 {
    const h = fnv1a64(source);
    const n = source.len;

    // Cache lookup
    for (&mermaid_cache) |*entry| {
        if (entry.hash == h and entry.len == n and entry.svg != null) {
            return alloc.dupe(u8, entry.svg.?); // hit: memcpy only
        }
    }

    // Cache miss: render and store (always page_alloc so it outlives resets)
    const svg = try pozeiden.render(page_alloc, source);

    const slot = &mermaid_cache[mermaid_cache_cursor];
    if (slot.svg) |old| page_alloc.free(old);
    slot.* = .{ .hash = h, .len = n, .svg = svg };
    mermaid_cache_cursor = (mermaid_cache_cursor + 1) % MERMAID_CACHE_SLOTS;

    return alloc.dupe(u8, svg);
}

// ── Persistent result ─────────────────────────────────────────────────────────
// Tracks the last rendered buffer so JS can read it via result_len() and the
// returned pointer.  We track which allocator owns it so we free correctly.
var last_result: ?[]u8 = null;
const ResultKind = enum { page, arena, fba };
var last_result_kind: ResultKind = .page;

fn freeLastResult() void {
    if (last_result) |buf| {
        switch (last_result_kind) {
            .page => page_alloc.free(buf),
            // arena and fba reset themselves at the top of their render fns.
            .arena, .fba => {},
        }
        last_result = null;
    }
}

// ── Exported API ─────────────────────────────────────────────────────────────

/// Parse Markdown and render to HTML using page_allocator (baseline).
/// The pointer is valid until the next call to any render function.
export fn render_html(input: [*]const u8, len: usize) usize {
    freeLastResult();
    const slice = input[0..len];
    var parser = zigmark.Parser.init();
    var doc = parser.parseMarkdown(page_alloc, slice) catch return 0;
    defer doc.deinit(page_alloc);
    var aw: std.Io.Writer.Allocating = .init(page_alloc);
    defer aw.deinit();
    zigmark.renderHtmlWithMermaid(page_alloc, &aw.writer, doc, cachedMermaidRender) catch return 0;
    const buf = aw.toOwnedSlice() catch return 0;
    last_result = buf;
    last_result_kind = .page;
    return @intFromPtr(buf.ptr);
}

/// Same render using a persistent ArenaAllocator (retain_capacity reset).
/// After the first call the pages are already mapped; subsequent calls only
/// bump a pointer — no memory.grow syscalls.
export fn render_html_arena(input: [*]const u8, len: usize) usize {
    freeLastResult();
    _ = render_arena.reset(.retain_capacity);
    const aa = render_arena.allocator();
    const slice = input[0..len];
    var parser = zigmark.Parser.init();
    const doc = parser.parseMarkdown(aa, slice) catch return 0;
    var aw: std.Io.Writer.Allocating = .init(aa);
    zigmark.renderHtmlWithMermaid(aa, &aw.writer, doc, cachedMermaidRender) catch return 0;
    const buf = aw.toOwnedSlice() catch return 0;
    last_result = buf;
    last_result_kind = .arena;
    return @intFromPtr(buf.ptr);
}

/// Same render using a FixedBufferAllocator over a static 2 MB region.
/// Zero syscalls: pure pointer-bump from a pre-mapped buffer.
/// Returns 0 for documents whose working set exceeds ~2 MB.
export fn render_html_fba(input: [*]const u8, len: usize) usize {
    freeLastResult();
    render_fba.reset();
    const fa = render_fba.allocator();
    const slice = input[0..len];
    var parser = zigmark.Parser.init();
    const doc = parser.parseMarkdown(fa, slice) catch return 0;
    var aw: std.Io.Writer.Allocating = .init(fa);
    zigmark.renderHtmlWithMermaid(fa, &aw.writer, doc, cachedMermaidRender) catch return 0;
    const buf = aw.toOwnedSlice() catch return 0;
    last_result = buf;
    last_result_kind = .fba;
    return @intFromPtr(buf.ptr);
}

/// Same as render_html but with mermaid=null — measures the overhead of the
/// pozeiden mermaid scanning pass on content that has no mermaid blocks.
export fn render_html_nomermaid(input: [*]const u8, len: usize) usize {
    freeLastResult();
    const slice = input[0..len];
    var parser = zigmark.Parser.init();
    var doc = parser.parseMarkdown(page_alloc, slice) catch return 0;
    defer doc.deinit(page_alloc);
    var aw: std.Io.Writer.Allocating = .init(page_alloc);
    defer aw.deinit();
    zigmark.renderHtmlWithMermaid(page_alloc, &aw.writer, doc, null) catch return 0;
    const buf = aw.toOwnedSlice() catch return 0;
    last_result = buf;
    last_result_kind = .page;
    return @intFromPtr(buf.ptr);
}

/// Flush the mermaid SVG cache.  Call after programmatic content changes where
/// the same diagram source should force a fresh render.
export fn flush_mermaid_cache() void {
    for (&mermaid_cache) |*entry| {
        if (entry.svg) |svg| page_alloc.free(svg);
        entry.* = .{};
    }
    mermaid_cache_cursor = 0;
}

/// Parse only — discards the document immediately.  Used by the JS benchmark
/// to isolate parse time from render time.
export fn parse_only(input: [*]const u8, len: usize) usize {
    const slice = input[0..len];
    var parser = zigmark.Parser.init();
    var doc = parser.parseMarkdown(page_alloc, slice) catch return 0;
    doc.deinit(page_alloc);
    return 1; // non-zero = success
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
    const buf = page_alloc.alloc(u8, len) catch return 0;
    return @intFromPtr(buf.ptr);
}

/// Free a buffer previously returned by `alloc_buf`.
export fn free_buf(ptr: usize, len: usize) void {
    if (ptr == 0) return;
    const slice: [*]u8 = @ptrFromInt(ptr);
    page_alloc.free(slice[0..len]);
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
    var doc = parser.parseMarkdown(page_alloc, slice) catch return 0;
    defer doc.deinit(page_alloc);

    const buf = renderer.render(page_alloc, doc) catch return 0;
    last_result = buf;
    last_result_kind = .page;
    return @intFromPtr(buf.ptr);
}
