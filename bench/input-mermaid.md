# Architecture Overview

This document contains representative mermaid diagrams for benchmark purposes.
It measures how parsers handle fenced code blocks with diagram content.

## System Architecture

```mermaid
flowchart TD
    Client[Browser / CLI] --> Parser
    Parser --> AST[Abstract Syntax Tree]
    AST --> HTML[HTML Renderer]
    AST --> Typst[Typst Renderer]
    AST --> AI[AI Renderer]
    HTML --> Mermaid[Mermaid diagrams via pozeiden]
    Mermaid --> SVG[Inline SVG]
```

## Request Lifecycle

```mermaid
sequenceDiagram
    participant U as User
    participant B as Browser
    participant W as zigmark.wasm
    participant P as pozeiden

    U->>B: types Markdown
    B->>W: alloc_buf + render_html
    W->>W: Parser.parseMarkdown
    W->>W: HTMLRenderer
    W->>P: render(mermaid_src)
    P-->>W: SVG string
    W-->>B: HTML with inline SVG
    B->>U: live preview
```

## Parsing Pipeline

```mermaid
flowchart LR
    Input[Raw Markdown] --> Tokenizer
    Tokenizer --> Lexer
    Lexer --> BlockParser[Block Parser]
    BlockParser --> InlineParser[Inline Parser]
    InlineParser --> AST
    AST --> HTMLRenderer
    AST --> ASTRenderer
    AST --> AIRenderer
```

## Renderer Output Formats

```mermaid
pie title Renderer usage distribution
    "HTML" : 60
    "Typst / PDF" : 20
    "AI / LLM" : 15
    "AST / Debug" : 5
```

## State Machine: Parser States

```mermaid
stateDiagram-v2
    [*] --> Start
    Start --> InBlock: blank line
    Start --> InParagraph: text
    InParagraph --> InBlock: blank line
    InParagraph --> InParagraph: more text
    InBlock --> InFenced: ``` marker
    InFenced --> InBlock: closing ```
    InBlock --> [*]: EOF
```

## Memory Management

```mermaid
flowchart TD
    A[page_allocator] --> B[ArenaAllocator.init]
    B --> C{render call}
    C --> D[parse allocations]
    C --> E[render allocations]
    D --> F[arena.reset retain_capacity]
    E --> F
    F --> C
```

## GFM Tables (non-diagram content for balance)

| Renderer   | Output      | Mermaid | Speed   |
| ---------- | ----------- | ------- | ------- |
| HTML       | `.html`     | yes     | fast    |
| Typst      | `.typ`      | no      | fast    |
| AI         | plain text  | no      | fastest |
| AST        | tree        | no      | fast    |

## Task list

- [x] CommonMark 652/652 tests
- [x] GFM extensions
- [x] Mermaid via pozeiden
- [x] WASM target
- [ ] SIMD optimisation

## Code (non-diagram fenced block)

```zig
const Parser = zigmark.Parser.init();
const doc = try parser.parseMarkdown(alloc, markdown);
defer doc.deinit(alloc);
const html = try zigmark.HTMLRenderer.render(alloc, doc);
```

---

_Benchmark input — contains 6 mermaid blocks and representative GFM content._
