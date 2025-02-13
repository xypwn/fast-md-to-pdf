parse :: (code: string) -> Document {
    input := Input.{
        text = code,
    };
    output: Document;
    parse_toplevel(*input, *output);
    return output;
}

Document :: struct {
    tokens: [..]Token;
    images: [..]Image;
    links:  [..]string;
}

Image :: struct {
    alt:  string;
    path: string;
}

Token_Type :: enum u8 {
    ERROR :: 0;
    CHAR;
    WORD_BREAK;
    LINE_BREAK;
    HORIZONTAL_RULE;
    IMAGE;
}

Token :: struct {
    type: Token_Type;
    union {
        char: struct {
            char: u8;
            modifiers: Char_Modifiers;
            link_index: s16 = -1;
            image_index: s16 = -1;
        }
        line_break: struct {
            previous_modifiers: Char_Modifiers;
        }
    }
}

Char_Modifiers :: enum u16 {
    ITALIC        :: 1 << 0;
    BOLD          :: 1 << 1;
    STRIKETHROUGH :: 1 << 2;
    MONOSPACE     :: 1 << 3;

    SCRIPT_BITS :: 0b11 << 4;
    SUBSCRIPT   :: 1 << 4;
    SUPERSCRIPT :: 2 << 4;

    HEADING_BITS :: 0b111 << 6;
    H1           :: 1 << 6;
    H2           :: 2 << 6;
    H3           :: 3 << 6;
    H4           :: 4 << 6;
    H5           :: 5 << 6;
    H6           :: 6 << 6;

    // Generate combinations like ITALIC_BOLD,
    // ITALIC_BOLD_STRIKETHROUGH, H1_MONOSPACE etc.
    #insert #run char_modifier_combinations();
}

#scope_file

parse_toplevel :: (using input: *Input, output: *Document) {
    section_start := cursor;

    parse_section :: inline (section: Input, output: *Document, modifiers: Char_Modifiers = 0) #expand {
        parse_text(*section, output, modifiers);
        emit_line_break(output, modifiers);
    }

    while 1 {
        eat_spaces(input);

        c := peek_char(input);
        if c == -1 {
            parse_section(slice(input, section_start, cursor), output);
            break;
        }

        // Parsing in this stage is done line-wise.
        // We want to split up the markdown text into
        // atomic sections, which will then be parsed
        // individually.
        // We should always land on a newline here.

        line_start := cursor;
        eat_spaces(input);
        c = peek_char(input);
        if is_newline(c) { // empty line
            parse_section(slice(input, section_start, line_start), output);
            section_start = cursor;
        } else if c == #char "*" { // horizontal rule
            num_stars := eat_while(input, #char "*");
            if num_stars >= 3 {
                eat_spaces(input);
                c = peek_char(input);
                if is_newline(c) {
                    parse_section(slice(input, section_start, line_start), output);
                    emit_token(output, .{type = .HORIZONTAL_RULE});
                    section_start = cursor;
                }
            }
        } else if c == #char "`" { // backticked code block
            num_backticks := eat_while(input, #char "`");
            first_line_start := cursor;
            first_line_end: Position;
            if num_backticks >= 3 {
                is_inline := false;
                while 1
                { // Try to find matching backticks on same line.
                    c = peek_char(input);
                    if is_newline(c) {
                        first_line_end = cursor;
                        eat_newline(input);
                        break;
                    }
                    if eat_while(input, #char "`") >= num_backticks {
                        is_inline = true;
                        break;
                    }
                    eat_char(input);
                }
                if !is_inline
                { // Code block is multi-line.
                    content_start := cursor;
                    content_end: Position;
                    while 1 {
                        c = peek_char(input);
                        content_end = cursor;
                        if c == -1 {
                            break;
                        }
                        if is_newline(c) {
                            eat_newline(input);
                            eat_spaces(input);
                            if eat_while(input, #char "`") >= num_backticks {
                                eat_spaces(input);
                                if is_newline(peek_char(input)) {
                                    break;
                                }
                            }
                        }
                        eat_char(input);
                    }
                    //language := slice(input, first_line_start, first_line_end);
                    // TODO: Syntax highlighting?
                    content := slice(input, content_start, content_end);
                    while 1 { // Emit content text
                        c := peek_char(*content);
                        if c == -1  break;
                        else if is_newline(c) {
                            eat_newline(*content);
                            emit_line_break(output, 0);
                        } else {
                            emit_char(output, c, .MONOSPACE);
                            eat_char(*content);
                        }
                    }
                    section_start = cursor;
                    emit_line_break(output, 0);
                } // end is_inline
            } // end if num_backticks >= 3
        } else if c == #char "#" { // heading
            heading_level := eat_while(input, #char "#");
            if heading_level <= 6 {
                heading_modifier := Char_Modifiers.[0, .H1, .H2, .H3, .H4, .H5, .H6][heading_level];

                heading_text_start := cursor;
                c = peek_char(input);
                if is_space(c) {
                    eat_spaces(input);
                    eat_while(input, (c) => !is_newline(c));
                    parse_section(slice(input, section_start, line_start), output);
                    parse_section(
                        slice(input, heading_text_start, cursor),
                        output,
                        heading_modifier,
                    );
                    section_start = cursor;
                }
            }
        }

        eat_while(input, (c) => !is_newline(c));
        eat_newline(input);
    }
}

parse_text :: (input: *Input, output: *Document, modifiers: Char_Modifiers) -> err: string {
    handle_modifier :: (
        using input: *Input, output: *Document, modifiers: Char_Modifiers,
        modifier_chars: string, modifier_flags: Char_Modifiers
    ) -> bool {
        if !eat_if_next_chars(input, modifier_chars)
            return false;

        // Don't nest the same modifier.
        if modifiers & modifier_flags
            return false;

        content_start := cursor;
        while 1 {
            c := peek_char(input);
            if c == -1 {
                emit_text(output, modifier_chars, modifiers);
                cursor = content_start;
                break;
            }
            pos := cursor;
            if eat_if_next_chars(input, modifier_chars) {
                content_end := pos;
                content := slice(input.*, content_start, content_end);
                err := parse_text(*content, output, modifiers | modifier_flags);
                assert(err == "");
                break;
            }
            eat_char(input);
        }
        return true;
    }

    eat_newlines_and_spaces(input);
    c := peek_char(input);
    if c == -1  return "";

    last_was_space := false;
    while 1 {
        c = peek_char(input);
        if c == -1  break;
        if is_space(c) || is_newline(c) {
            eat_newlines_and_spaces(input);
            last_was_space = true;
        } else if handle_modifier(input, output, modifiers, "***", .ITALIC_BOLD) {
        } else if handle_modifier(input, output, modifiers, "**", .BOLD) {
        } else if handle_modifier(input, output, modifiers, "*", .ITALIC) {
        } else if handle_modifier(input, output, modifiers, "___", .ITALIC_BOLD) {
        } else if handle_modifier(input, output, modifiers, "__", .BOLD) {
        } else if handle_modifier(input, output, modifiers, "_", .ITALIC) {
        } else if handle_modifier(input, output, modifiers, "~~", .STRIKETHROUGH) {
        } else if !(modifiers & .SUPERSCRIPT) &&
            handle_modifier(input, output, modifiers, "~", .SUBSCRIPT) {
        } else if !(modifiers & .SUBSCRIPT) &&
            handle_modifier(input, output, modifiers, "^", .SUPERSCRIPT) {
        } else {
            if last_was_space {
                emit_token(output, .{type = .WORD_BREAK});
                last_was_space = false;
            }
            emit_char(output, c, modifiers);
            eat_char(input);
        }
    }

    return "";
}

char_modifier_combinations :: () -> string #expand {
    result: String_Builder;
    headings := string.["", "H1", "H2", "H3", "H4", "H5", "H6"];
    scripts := string.["", "SUBSCRIPT", "SUPERSCRIPT"];
    items := string.["ITALIC", "BOLD", "STRIKETHROUGH", "MONOSPACE"];
    for heading : headings
    for script : scripts
    for perm : 0..(1<<items.count - 1) {
        elements: [..]string;
        if heading
            array_add(*elements, heading);
        if script
            array_add(*elements, script);
        for item, item_index : items {
            flag := 1 << item_index;
            if perm & flag
                array_add(*elements, item);
        }
        if elements.count > 1 {
            print(*result, "% :: %;\n",
                join(..elements, "_"),
                join(..elements, " | "),
            );
        }
    }
    return builder_to_string(*result);
}

emit_line_break :: (using output: *Document, previous_modifiers: Char_Modifiers) {
    inline emit_token_unless_last_type(output, .{
        type = .LINE_BREAK,
        line_break = .{
            previous_modifiers = previous_modifiers,
        },
    }, .LINE_BREAK, .HORIZONTAL_RULE);
}

emit_token_unless_last_type :: (using output: *Document, token: Token, exclude_types: .. Token_Type) {
    if tokens.count == 0
    || !array_find(exclude_types, tokens[tokens.count-1].type) {
        emit_token(output, token);
    }
}

emit_token :: inline (output: *Document, token: Token) {
    array_add(*output.tokens, token);
}

emit_char :: inline (output: *Document, char: s16, modifiers: Char_Modifiers) {
    if char != -1
        emit_char(output, char.(u8), modifiers);
}

emit_char :: inline (output: *Document, char: u8, modifiers: Char_Modifiers) {
    emit_token(output, .{
        type = .CHAR,
        char = .{
            char = char,
            modifiers = modifiers,
        },
    });
}

emit_text :: inline (output: *Document, text: string, modifiers: Char_Modifiers) {
    for text
        emit_char(output, it, modifiers);
}

Position :: struct {
    current_line: s32;
    current_char_in_line: s32;
    cursor: s64;
}

Input :: struct {
    cursor:      Position;
    text:        string;
}

// @Note: Works differently from String's slice!
// Instead of start and count, we have start and end.
// End is exclusive.
slice :: (input: Input, start: Position, end: Position) -> Input {
    return .{
        cursor = .{
            current_line         = start.current_line,
            current_char_in_line = start.current_char_in_line,
        },
        text = slice(input.text, start.cursor, end.cursor - start.cursor),
    };
}

eat_char :: (using input: *Input) {
    if cursor.cursor >= text.count  return;
    if text[cursor.cursor] == #char "\n" {
        cursor.current_line += 1;
        cursor.current_char_in_line = 0;
    } else
        cursor.current_char_in_line += 1;
    cursor.cursor += 1;
}

peek_char :: (using input: *Input) -> s16 {
    if cursor.cursor >= text.count  return -1;
    return text[cursor.cursor];
}

eat_spaces :: inline (input: *Input) -> ate: bool {
    return eat_while(input, (_, c) => is_space(c), void) > 0;
}

eat_newlines_and_spaces :: inline (input: *Input) -> ate: bool {
    ate_any := false;
    while 1 {
        ate := false;
        c := peek_char(input);
        if c == -1  break;
        if is_newline(c) {
            eat_newline(input);
            ate = true;
        }
        c = peek_char(input);
        if is_space(c) {
            eat_spaces(input);
            ate = true;
        }
        if ate  ate_any = true;
        else    break;
    }
    return ate_any;
}

eat_while :: (input: *Input, char: s16, max_chars := -1) -> num_eaten: s64 {
    return inline eat_while(input, (match, c) => match == c, char, max_chars);
}

eat_while :: (input: *Input, $condition: (c: s16) -> bool, max_chars := -1) -> num_eaten: s64 {
    return inline eat_while(input, (_, c) => condition(c), void, max_chars);
}

eat_while :: (input: *Input, $condition: (data: T, c: s16) -> bool, data: $T, max_chars := -1) -> num_eaten: s64 {
    num_eaten := 0;
    while 1 {
        c := peek_char(input);
        if num_eaten == max_chars || !(inline condition(data, c))
            break;
        eat_char(input);
        num_eaten += 1;
    }
    return num_eaten;
}

eat_if_next_chars :: (using input: *Input, sequence: string) -> bool {
    start := cursor;
    for sequence {
        c := peek_char(input);
        if c != it {
            cursor = start;
            return false;
        }
        eat_char(input);
    }
    return true;
}

eat_newline :: inline (input: *Input) {
    c := peek_char(input);
    if c == #char "\r" {
        eat_char(input);
        c = peek_char(input);
    }
    if c == #char "\n"
        eat_char(input);
}

is_newline :: (c: s16) -> bool {
    return c == -1 || c == #char "\n" || c == #char "\r";
}

is_space :: (c: s16) -> bool {
    return c == #char " " || c == #char "\t";
}

#import "Basic";
#import "String";