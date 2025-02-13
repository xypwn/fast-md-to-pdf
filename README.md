# Fast MD to PDF
Addressing the severe lack of Markdown to PDF converters with reasonable speed.

Both the Markdown parser and PDF generator are written from scratch, so **many features are still missing**.

## Building
```
$ jai -version
Version: beta 0.2.009, built on 6 February 2025.
```
```
$ jai first.jai -x64
```

## Usage
```
$ ./fast-md-to-pdf input_file.md [output_file[.pdf]] [-watch]
```

## Features
- High performance (PDFs usually compile in a few ms)
- Automatic document recompilation (`-watch` option)

## Supported Markdown Features
### Present
- Paragraph text (duh)
- Headings
- Styling: Bold, Italic
- Code block
- Horizontal rule

### Missing
- Backslash escaping
- Bullet lists
- Numbered lists
- Checkbox lists
- Tables
- HTML tag syntax
- Block quotes
- Images
- Links
- Alternative horizontal rule syntax
- Inline code blocks
- Syntax highlighting (not really planned because seems complicated)