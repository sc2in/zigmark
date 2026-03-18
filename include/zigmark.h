/*
 * zigmark — C API for the Zig Markdown parser & renderers.
 *
 * Copyright © 2025 Star City Security Consulting, LLC (SC2)
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#ifndef ZIGMARK_H
#define ZIGMARK_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/** Opaque handle to a parsed Markdown document. */
typedef struct ZigmarkDocument ZigmarkDocument;

/**
 * Parse a UTF-8 Markdown buffer of @p len bytes.
 *
 * @param input  Pointer to the Markdown source text (need not be NUL-terminated).
 * @param len    Length of the input in bytes.
 * @return       An opaque document handle, or NULL on failure.
 *               Free with zigmark_free_document().
 */
ZigmarkDocument *zigmark_parse(const char *input, size_t len);

/**
 * Free a document previously returned by zigmark_parse().
 */
void zigmark_free_document(ZigmarkDocument *doc);

/**
 * Render the document to CommonMark-compliant HTML.
 *
 * @return A NUL-terminated string, or NULL on failure.
 *         Free with zigmark_free_string().
 */
char *zigmark_render_html(ZigmarkDocument *doc);

/**
 * Render the document to a human-readable AST tree diagram.
 *
 * @return A NUL-terminated string, or NULL on failure.
 *         Free with zigmark_free_string().
 */
char *zigmark_render_ast(ZigmarkDocument *doc);

/**
 * Render the document to a token-efficient AI representation.
 *
 * @return A NUL-terminated string, or NULL on failure.
 *         Free with zigmark_free_string().
 */
char *zigmark_render_ai(ZigmarkDocument *doc);

/**
 * Free a string previously returned by one of the render functions.
 */
void zigmark_free_string(char *str);

/**
 * Return the library version as a static NUL-terminated string.
 * The pointer is valid for the lifetime of the process.
 */
const char *zigmark_version(void);

/* ── Frontmatter ──────────────────────────────────────────────────────────── */

/** Opaque handle to parsed frontmatter metadata. */
typedef struct ZigmarkFrontmatter ZigmarkFrontmatter;

/**
 * Parse frontmatter from a UTF-8 Markdown buffer of @p len bytes.
 *
 * Auto-detects the format:
 *   - YAML  — opening @c ---
 *   - TOML  — opening @c +++
 *   - JSON  — opening @c {
 *   - ZON   — opening @c .{
 *
 * @param input  Pointer to the Markdown source (need not be NUL-terminated).
 * @param len    Length of the input in bytes.
 * @return       An opaque frontmatter handle, or NULL if no valid frontmatter
 *               is present or on parse / allocation failure.
 *               Free with zigmark_frontmatter_free().
 */
ZigmarkFrontmatter *zigmark_frontmatter_parse(const char *input, size_t len);

/**
 * Free a frontmatter handle previously returned by zigmark_frontmatter_parse().
 */
void zigmark_frontmatter_free(ZigmarkFrontmatter *fm);

/**
 * Serialize the entire frontmatter to a pretty-printed JSON string.
 *
 * @return A NUL-terminated JSON string, or NULL on failure.
 *         Free with zigmark_free_string().
 */
char *zigmark_frontmatter_to_json(ZigmarkFrontmatter *fm);

/**
 * Look up a dot-separated key path in the frontmatter and return its value
 * as a compact JSON string.
 *
 * Examples: @c "title", @c "extra.author", @c "tags"
 *
 * @param fm   A handle returned by zigmark_frontmatter_parse().
 * @param key  A NUL-terminated dot-separated key path.
 * @return     A NUL-terminated JSON string for the value, or NULL if the key
 *             is not found or on failure.
 *             Free with zigmark_free_string().
 */
char *zigmark_frontmatter_get(ZigmarkFrontmatter *fm, const char *key);

/**
 * Serialize the frontmatter back to its original format, including delimiters.
 *
 * The output reflects the current state of the parsed value tree, so any
 * programmatic modifications are included.  The format matches whatever was
 * originally detected at parse time:
 *
 * | Format | Delimiters | Example output              |
 * |--------|------------|-----------------------------|
 * | YAML   | `---`      | `---\ntitle: Hello\n---\n`  |
 * | TOML   | `+++`      | `+++\ntitle = "Hello"\n+++\n`|
 * | JSON   | none       | `{\n  "title": "Hello"\n}\n` |
 * | ZON    | none       | `.{ .title = "Hello" }\n`   |
 *
 * @param fm  A handle returned by zigmark_frontmatter_parse().
 * @return    A NUL-terminated string in the original format, or NULL on
 *            failure.  Free with zigmark_free_string().
 */
char *zigmark_frontmatter_serialize(ZigmarkFrontmatter *fm);

/**
 * Deep-merge @p overlay into @p base (overlay keys win for leaf conflicts).
 *
 * The merge is recursive for object values: keys present only in the overlay
 * are added to the base; keys present in both are overwritten (scalar) or
 * recursively merged (object).  The base retains its original format.
 *
 * @param base     The document to merge into; modified in place.
 * @param overlay  The document to merge from; left unmodified.
 * @return         0 on success, -1 on failure.
 */
int zigmark_frontmatter_merge(ZigmarkFrontmatter *base,
                              const ZigmarkFrontmatter *overlay);

/**
 * Set a value at a dot-separated key path using a JSON-encoded value string.
 *
 * Intermediate objects that do not exist are created automatically.
 *
 * @param fm         A handle returned by zigmark_frontmatter_parse().
 * @param path       NUL-terminated dot-separated key path (e.g. @c "extra.owner").
 * @param json_value NUL-terminated compact JSON string for the new value
 *                   (e.g. @c "\"hello\"", @c "42", @c "true", @c "[1,2]").
 * @return           0 on success, -1 on failure (bad JSON, OOM, or bad path).
 */
int zigmark_frontmatter_set(ZigmarkFrontmatter *fm,
                            const char *path,
                            const char *json_value);

/**
 * Set a value at a dot-separated key path using an auto-typed raw string.
 *
 * Type inference rules (applied in order):
 *   - @c "true" / @c "false" → boolean
 *   - @c "null" → null
 *   - Valid integer literal (no @c .) → integer
 *   - Valid float literal → float
 *   - Everything else → string
 *
 * Intermediate objects that do not exist are created automatically.
 *
 * @param fm    A handle returned by zigmark_frontmatter_parse().
 * @param path  NUL-terminated dot-separated key path.
 * @param raw   NUL-terminated raw value string.
 * @return      0 on success, -1 on failure.
 */
int zigmark_frontmatter_set_raw(ZigmarkFrontmatter *fm,
                                const char *path,
                                const char *raw);

#ifdef __cplusplus
}
#endif

#endif /* ZIGMARK_H */
