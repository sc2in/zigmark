/// Basic token types for the lexer
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

/// A token with its type and content
pub const Token = struct {
    type: TokenType = .eof,
    content: []const u8 = "",
    src: Range = .{},
};
pub const EOF = Token{};

/// Position information for source mapping
pub const Position = struct {
    line: usize = 0,
    column: usize = 0,
    offset: usize = 0,
};
/// Range in source text
pub const Range = struct {
    start: Position = .{},
    end: Position = .{},
};
