//! Lexer token definitions for the Markdown parser.
//!
//! These types are used internally by the parser to classify individual
//! characters and track their source positions.

/// Discriminator for the kind of lexer token.
pub const TokenType = enum {
    text,
    whitespace,
    newline,
    hash,
    equals,
    dash,
    underscore,
    asterisk,
    plus,
    gt,
    backtick,
    tilde,
    lbracket,
    rbracket,
    lparen,
    rparen,
    caret,
    colon,
    digit,
    backslash,
    lt,
    eof,
};

/// A single lexer token carrying its type, source text, and location.
pub const Token = struct {
    type: TokenType = .eof,
    content: []const u8 = "",
    src: Range = .{},
};

/// Sentinel token representing end-of-input.
pub const EOF = Token{};

/// A zero-based line/column/byte-offset position in the source text.
pub const Position = struct {
    line: usize = 0,
    column: usize = 0,
    offset: usize = 0,
};

/// A half-open range in the source text, defined by a start and end `Position`.
pub const Range = struct {
    start: Position = .{},
    end: Position = .{},
};
