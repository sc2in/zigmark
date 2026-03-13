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

#ifdef __cplusplus
}
#endif

#endif /* ZIGMARK_H */
