# Fast MD to PDF
This is mostly an experiment for learning the JAI programming language.

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
#### CLI Options
```
$ ./fast-md-to-pdf input_file.md [output_file[.pdf]] [-watch]
```

#### Basic example (this README)
```
$ ./fast-md-to-pdf README.md
```

## Features
- High performance (PDFs usually compile in a few ms)
- Automatic document recompilation (`-watch` option)

## Supported Markdown Features
### Present
- Paragraph text (duh)
- Headings
- Styling: Bold, Italic, Subscript, Superscript, Code
- Code blocks
- Horizontal rules
- Backslash escaping
- Bullet lists

### Missing
- Numbered lists
- Checkbox lists
- Styling: Strikethrough
- Tables
- HTML tag syntax
- Block quotes
- Images
- Links
- Alternative horizontal rule syntax
- Syntax highlighting (not really planned because it seems complicated)