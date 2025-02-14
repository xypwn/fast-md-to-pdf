#module_parameters(
    // Draw debug shapes on the resulting page.
    PAGE_DEBUG_FLAGS := Page_Debug_Flags.NONE
) {
    Page_Debug_Flags :: enum {
        NONE       :: 0;
        MARGINS    :: 1 << 0;
        TEXT_LINES :: 1 << 1;
        IMAGES     :: 1 << 2;
        ALL        :: MARGINS | TEXT_LINES | IMAGES;
    }
};

// ISO 216 / DIN A Series
A0  :: Dimensions.{2384, 3370};
A1  :: Dimensions.{1684, 2384};
A2  :: Dimensions.{1191, 1684};
A3  :: Dimensions.{ 842, 1191};
A4  :: Dimensions.{ 595,  842};
A5  :: Dimensions.{ 420,  595};
A6  :: Dimensions.{ 298,  420};
A7  :: Dimensions.{ 210,  298};
A8  :: Dimensions.{ 147,  210};
A9  :: Dimensions.{ 105,  147};
A10 :: Dimensions.{  74,  105};

// Burger Formats
LETTER  :: Dimensions.{612,  792};
LEGAL   :: Dimensions.{612, 1008};
TABLOID :: Dimensions.{792, 1224};

Item_Type :: enum u8 {
    TEXT;
    NEWLINE;
    VSPACE;
    HSPACE;
    HRULE;
    IMAGE;
}

Text_Font_Properties :: struct {
    font_size: s32 = 10; // font size in pt
    rise: s32 = 0;       // vertical offset in pt (e.g. for sub-/superscript)
    xfloat: s32 = 0;     // if nonzero: text has no width and has the specified X offset in pt
    strikethrough := false; // TODO
}

operator == :: inline (a: Text_Font_Properties, b: Text_Font_Properties) -> bool {
    return a.font_size == b.font_size
        && a.rise == b.rise;
}

Item :: struct {
    Text :: struct {
        allow_split_on_page: bool = false; // TODO

        // Spread out words in a paragraph similarly to
        // LaTeX.
        spread_words: bool = true;

        Word :: struct {
            Block :: struct {
                using properties: Text_Font_Properties;
                font: string = "Helvetica"; // a builtin PDF font (see CORE_FONTS)
                text: string;
            }
            blocks: []Block;
        }

        words: []Word;
    }

    type: Item_Type;

    // Additional left margin in pt (e.g. for
    // block quotes).
    indent: s32 = 0;

    union {
        text: Text;
        vspace: s32;
        hspace: s32;
        image_index: s32;
    }
}

Dimensions :: struct {
    // In pt.
    width:  s32;
    height: s32;
}

Page_Format :: struct {
    using dimensions: Dimensions;
    margin_left:   s32 = 72;
    margin_right:  s32 = 72;
    margin_top:    s32 = 72;
    margin_bottom: s32 = 72;
}

Image :: struct {
    data: string;
    width:  s32;
    height: s32;
}

PDF :: struct {
    next_object_number: s32 = 1;
    object_offsets: [..]s64;
    builder: String_Builder;
}

write :: (page_format: Page_Format, items: []Item, images: []Image = .[]) -> string {
    pdf := PDF.{};
    pdf_write_header(*pdf);

    fonts: [..]*Core_Font;

    Page :: struct {
        dependencies: struct {
            font_indices: [..]s32;
            image_indices: [..]s32;
        }
        contents: string;
    }
    pages: [..]Page;

    Page_Info :: struct {
        // pt = point = 1 inch / 72
        min_text_x_pt: s32;
        min_text_y_pt: s32;
        max_text_x_pt: s32;
        max_text_y_pt: s32;
    }
    page_info := Page_Info.{
        min_text_x_pt = page_format.margin_left,
        min_text_y_pt = page_format.margin_bottom,
        max_text_x_pt = page_format.width - page_format.margin_right,
        max_text_y_pt = page_format.height - page_format.margin_top,
    };

    {
        // fonts is the set of fonts actually used in the PDF. If font_name doesn't
        // exist in fonts yet, it will be added.
        // If the font is available, this returns the font struct and index in fonts.
        // If the font isn't available, ok is false and values for Helvetica are returned.
        get_or_add_font :: (fonts: *[..]*Core_Font, font_name: string) -> font: *Core_Font, font_index: s32, ok: bool {
            for fonts.* {
                if it.name == font_name
                    // Font already exists in PDF document.
                    return it, it_index.(s32), true;
            }
            // Find font in available fonts.
            font: *Core_Font = *CORE_FONTS[0];
            for * CORE_FONTS {
                if equal_nocase(it.name, font_name) {
                    array_add(fonts, it);
                    return it, (fonts.count-1).(s32), true;
                }
            }
            // Not found -> use Helvetica.
            // This shouldn't happen too often,
            // so we can allow it to be a bit slow.
            {
                font, font_index, ok := get_or_add_font(fonts, "Helvetica");
                return font, font_index, ok;
            }
        }

        // Resolve all used fonts.
        Resolved_Block_Font :: struct {
            #as using font: *Core_Font;
            font_index: s32;
        }
        resolved_block_fonts: [..][..][..]Resolved_Block_Font;
        for item, item_index : items {
            array_add(*resolved_block_fonts, [..][..]Resolved_Block_Font.{});
            if item.type == .TEXT {
                for word, word_index : item.text.words {
                    array_add(*resolved_block_fonts[item_index], [..]Resolved_Block_Font.{});
                    for block, block_index : word.blocks {
                        font, font_index := get_or_add_font(*fonts, block.font);
                        array_add(*resolved_block_fonts[item_index][word_index], .{
                            font=font,
                            font_index=font_index,
                        });
                    }
                }
            }
        }

        print_pdf_escaped_char :: (builder: *String_Builder, c: u8) {
            if c == {
                case #char "\n"; append(builder, "\\n");  // newline
                case #char "\r"; append(builder, "\\r");  // carriage return
                case #char "\t"; append(builder, "\\t");  // horizontal tab
                case 0x08;       append(builder, "\\b");  // backspace
                case 0x0C;       append(builder, "\\f");  // form feed
                case #char "\\"; append(builder, "\\\\"); // backslash
                case #char "(";  append(builder, "\\(");
                case #char ")";  append(builder, "\\)");
                case;
                    if c >= 32 && c <= 126
                        append(builder, c);
                    else {
                        append(builder, "\\");
                        print_integer(builder, .{value=c, minimum_digits=3, base=8});
                    }
            }
        }

        Render_State :: struct {
            Word :: struct {
                #as using word: Item.Text.Word;
                block_fonts: []Resolved_Block_Font;
            }

            prepend_new_page := true;
            is_new_block: bool;

            // pt = point = 1 inch / 72
            // mpt = milli-point = 1 pt / 1000
            next_char_x_mpt: s32;
            next_char_y_pt:  s32;

            prev_space_width_mpt: s32;
            skip_chars_in_next_line: s32;

            prepend_new_lines: s32;

            current_font_properties: Text_Font_Properties;
            current_font: *Core_Font;

            current_page_text_cmds: String_Builder;
            current_page_draw_cmds: String_Builder;
            current_words:          [..]Word;       // words in current line

            currently_used_font_indices: [..]s32;  // font indices used on current page
            currently_used_image_indices: [..]s32; // image indices used on current page
        }
        rs: Render_State;

        is_current_font :: inline (rs: *Render_State, font: Resolved_Block_Font, font_properties: Text_Font_Properties) -> bool {
            return font.font == rs.current_font && font_properties == rs.current_font_properties;
        }

        ensure_font :: (rs: *Render_State, font: Resolved_Block_Font, font_properties: Text_Font_Properties) {
            if is_current_font(rs, font, font_properties)
                return;
            print(*rs.current_page_text_cmds, #string END
  /F% % Tf
  % TL
  % Ts
END,
                font.font_index+1, font_properties.font_size,
                font_properties.font_size,
                font_properties.rise,
            );
            array_add_if_unique(*rs.currently_used_font_indices, font.font_index);
            rs.current_font = font.font;
            rs.current_font_properties = font_properties;
        }

        flush_page :: (pages: *[..]Page, rs: *Render_State) {
            if builder_string_length(*rs.current_page_text_cmds) > 0 {
                array_add(pages, .{
                    contents=tprint(#string END
BT
%ET
q
%Q
END,
                        builder_to_string(*rs.current_page_text_cmds),
                        builder_to_string(*rs.current_page_draw_cmds),
                    ),
                    dependencies = .{
                        font_indices = rs.currently_used_font_indices,
                        image_indices = rs.currently_used_image_indices,
                    },
                });
            }
            rs.currently_used_font_indices.count = 0;
            rs.currently_used_font_indices.allocated = 0;
            rs.currently_used_font_indices.data = null;
            rs.currently_used_image_indices.count = 0;
            rs.currently_used_image_indices.allocated = 0;
            rs.currently_used_image_indices.data = null;
        }

        flush_current_line :: (rs: *Render_State, page_info: Page_Info, indent_mpt: s32, spread_words: bool, max_chars: s32 = -1) {
            //print("### %\n", rs.current_words);

            skip_chars := rs.skip_chars_in_next_line;
    
            // Max chars is intended for cutting off the first word in a line, if it is too long.
            // Spreading words doesn't make sense in that line.
            assert(max_chars == -1 || spread_words || rs.current_words.count <= 1, "cannot have max chars and spread words simultaneously");

            word_has_physical_content :: (w: Item.Text.Word) -> bool {
                for w.blocks if !it.xfloat && it.text
                    return true;
                return false;
            }

            CMD_TEXT_START :: "  [";
            CMD_TEXT_END   :: "] TJ\n";
            line_is_started := false;
            text_cmd_is_started := false;
            if rs.current_words {
                space_width_mpt: float;
                if spread_words && rs.current_words.count > 1 {
                    page_width_pt := page_info.max_text_x_pt - (page_info.min_text_x_pt + indent_mpt/1000);
                    space_count: s32;
                    chars_width_mpt := 0;
                    num_chars: s32;
                    is_first_word := true;
                    for word : rs.current_words {
                        has_content := word_has_physical_content(word);
                        if !is_first_word && num_chars >= skip_chars && has_content
                            space_count += 1;
                        for block, block_index : word.blocks {
                            font := word.block_fonts[block_index];
                            for block.text {
                                if num_chars >= skip_chars && !block.xfloat
                                    chars_width_mpt += font.glyph_widths[it] * block.font_size;
                                num_chars += 1;
                            }
                        }
                        if num_chars >= skip_chars && has_content
                            is_first_word = false;
                    }
                    space_left_width_mpt := page_width_pt * 1000 - chars_width_mpt;
                    space_width_mpt = space_left_width_mpt.(float) / space_count.(float);
                }
                num_chars: s32;
                for word, word_index : rs.current_words {
                    if skip_chars > 0 { // Skip whole word if possible.
                        word_chars: s32;
                        for word.blocks
                            word_chars += it.text.count.(s32);
                        if num_chars + word_chars < skip_chars {
                            num_chars += word_chars;
                            continue;
                        }
                    }
                    if max_chars != -1 && num_chars > max_chars
                      { // Immediately stop when past max chars.
                        break;
                    }
                    has_physical_content := word_has_physical_content(word);
                    for block, block_index : word.blocks {
                        font := word.block_fonts[block_index];
                        if !is_current_font(rs, font, block.properties) {
                            if text_cmd_is_started { // ensure we're not already in a text command
                                append(*rs.current_page_text_cmds, CMD_TEXT_END);
                                text_cmd_is_started = false;
                            }
                            ensure_font(rs, font, block.properties);
                        }
                        if !text_cmd_is_started { // ensure we're in a text command
                            append(*rs.current_page_text_cmds, CMD_TEXT_START);
                            text_cmd_is_started = true;
                            if !line_is_started {
                                // Add indent at beginning of line.
                                print_integer(*rs.current_page_text_cmds, .{value=-indent_mpt/block.font_size});
                                append(*rs.current_page_text_cmds, " ");
                                line_is_started = true;
                            }
                        }
                        xfloat_text_width := 0;
                        xfloat_offset := block.xfloat*1000/block.font_size;
                        if block.xfloat {
                            print_integer(*rs.current_page_text_cmds, .{value=-xfloat_offset});
                            append(*rs.current_page_text_cmds, " ");
                        }
                        append(*rs.current_page_text_cmds, " (");
                        for block.text {
                            if num_chars >= skip_chars && (max_chars == -1 || num_chars < max_chars) {
                                print_pdf_escaped_char(*rs.current_page_text_cmds, it);
                                if block.xfloat
                                    xfloat_text_width += font.glyph_widths[it];
                            }
                            num_chars += 1;
                        }
                        append(*rs.current_page_text_cmds, ") ");
                        if block.xfloat {
                            print_integer(*rs.current_page_text_cmds, .{value=xfloat_text_width+xfloat_offset});
                            append(*rs.current_page_text_cmds, " ");
                        }
                    }
                    if rs.current_font != null && word_index != rs.current_words.count-1 && has_physical_content {
                        space_width: float;
                        if space_width_mpt == 0
                            space_width = rs.current_font.glyph_widths[#char " "].(float);
                        else
                            space_width = space_width_mpt / rs.current_font_properties.font_size.(float);
                        print_float(*rs.current_page_text_cmds, .{value=-space_width});
                    }
                }
                if text_cmd_is_started { // end possible text command
                    append(*rs.current_page_text_cmds, CMD_TEXT_END);
                    text_cmd_is_started = false;
                }
            }

            #if PAGE_DEBUG_FLAGS & .TEXT_LINES {
                if rs.current_words.count > 0 && rs.current_words[0].blocks.count > 0 {
                    print(*rs.current_page_draw_cmds,
                        #string END
  0.5 0.0 0.5 RG
  % % % % re
  S
END,
                        page_info.min_text_x_pt,
                        rs.next_char_y_pt,
                        page_info.max_text_x_pt - page_info.min_text_x_pt,
                        rs.current_words[0].blocks[0].properties.font_size,
                    );
                }
            }

            rs.skip_chars_in_next_line = 0;
            array_reset_keeping_memory(*rs.current_words);
        }

        is_line_start := true;
        line_start_indent_mpt: s32 = 0;
        for item, item_index : items {
            rs.is_new_block = true;
            if item.type == .TEXT || item.type == .IMAGE {
                if is_line_start {
                    line_start_indent_mpt = item.indent*1000;

                    is_line_start = false;
                }
            }
            if item.type == .TEXT {
                Iter_State :: struct {
                    word_index := 0;
                    block_index := 0;
                    char_index := 0;
                }
                using iter_state: Iter_State;

                restore_iter_state_to_word_beginning := false;
                word_beginning_iter_state: Iter_State;

                while true {
                    // words contain blocks, blocks contain chars
                    if word_index >= item.text.words.count  
                        break;
                    word := item.text.words[word_index];
                    if block_index >= word.blocks.count {
                        block_index = 0;
                        word_index += 1;
                        continue;
                    }
                    block := word.blocks[block_index];
                    if char_index >= block.text.count {
                        char_index = 0;
                        block_index += 1;
                        continue;
                    }
                    char := block.text[char_index];

                    if block_index == 0 && char_index == 0 {
                        //print("bow\n");
                        word_beginning_iter_state = iter_state;
                    }

                    if restore_iter_state_to_word_beginning {
                        iter_state = word_beginning_iter_state;
                        restore_iter_state_to_word_beginning = false;
                    }

                    is_last_char_in_word :=
                        block_index == word.blocks.count-1
                        && char_index == block.text.count-1;

                    if rs.prepend_new_page {
                        flush_current_line(*rs, page_info, line_start_indent_mpt, false);
                        print(*rs.current_page_text_cmds,
                            "  % % Td \n",
                            page_info.min_text_x_pt,
                            page_info.max_text_y_pt - block.font_size,
                        );

                        #if PAGE_DEBUG_FLAGS & .MARGINS {
                            print(*rs.current_page_draw_cmds,
                                #string END
  0.0 0.5 0.5 RG

  % 0 m
  % % l

  % 0 m
  % % l

  0 % m
  % % l

  0 % m
  % % l
  S
END,
                                page_info.min_text_x_pt,
                                page_info.min_text_x_pt,
                                page_format.height,

                                page_info.max_text_x_pt,
                                page_info.max_text_x_pt,
                                page_format.height,

                                page_info.min_text_y_pt,
                                page_format.width,
                                page_info.min_text_y_pt,

                                page_info.max_text_y_pt,
                                page_format.width,
                                page_info.max_text_y_pt,
                            );
                        }


                        rs.next_char_y_pt = page_info.max_text_y_pt - block.font_size;

                        rs.current_font = null;
                        rs.current_font_properties = .{};
                    }
                    if rs.prepend_new_page || rs.prepend_new_lines > 0 {
                        rs.next_char_x_mpt = page_info.min_text_x_pt*1000 + line_start_indent_mpt;
                    }
                    font := resolved_block_fonts[item_index][word_index][block_index];
                    if rs.prepend_new_lines > 0 {
                        ensure_font(*rs, font, block.properties);
                        for 1..rs.prepend_new_lines {
                            append(*rs.current_page_text_cmds, "  T*\n");
                        }
                        rs.next_char_y_pt -= rs.prepend_new_lines*block.font_size;
                    }
                    rs.prepend_new_page = false;
                    rs.is_new_block = false;
                    rs.prepend_new_lines = 0;

                    inc_char := false;
                    glyph_width_mpt := ifx block.xfloat then 0 else font.glyph_widths[char] * block.font_size;
                    if
                      // New char would overflow the current line.
                      rs.next_char_x_mpt + glyph_width_mpt >= page_info.max_text_x_pt*1000
                      // Char CAN theoretically fit into the page width.
                      && page_info.min_text_x_pt*1000 + line_start_indent_mpt + glyph_width_mpt < page_info.max_text_x_pt*1000 {
                        if rs.current_words.count == 0 {
                            // The overflow happened in the first word
                            // => we have to chop the word up.
                            num_chars: s32; // how far we're into the current word
                            for i : 0..block_index-1 {
                                num_chars += word.blocks[i].text.count.(s32);
                            }
                            num_chars += char_index.(s32);
                            array_add(*rs.current_words, .{
                                word = word,
                                block_fonts = resolved_block_fonts[item_index][word_index],
                            });
                            flush_current_line(*rs, page_info, line_start_indent_mpt, false, max_chars=num_chars);
                            rs.skip_chars_in_next_line = num_chars;
                        } else {
                            flush_current_line(*rs, page_info, line_start_indent_mpt, item.text.spread_words);
                            restore_iter_state_to_word_beginning = true;
                        }
                        rs.prepend_new_lines += 1;
                    } else {
                        if 
                          // New char would overflow the current page.
                          rs.next_char_y_pt <= page_info.min_text_y_pt
                          // Char CAN theoretically fit into the page height.
                          && page_info.min_text_y_pt + block.font_size < page_info.max_text_y_pt {
                            flush_page(*pages, *rs);
                            rs.prepend_new_page = true;
                        } else
                            inc_char = true;
                    }
                    //print("% % % % % %\n", to_string(*char, 1), rs.current_words, is_last_char_in_word, rs.prev_space_width_mpt, rs.next_char_x_mpt, rs.next_char_y_pt);

                    rs.next_char_x_mpt += glyph_width_mpt;

                    if is_last_char_in_word && inc_char {
                        array_add(*rs.current_words, .{
                            word = word,
                            block_fonts = resolved_block_fonts[item_index][word_index],
                        });
                        rs.next_char_x_mpt += rs.prev_space_width_mpt;
                    }

                    rs.prev_space_width_mpt = font.glyph_widths[#char " "] * block.font_size;

                    if inc_char
                        char_index += 1;
                }
            } else if item.type == .NEWLINE {
                flush_current_line(*rs, page_info, line_start_indent_mpt, false);
                is_line_start = true;
                rs.prepend_new_lines += 1;
            } else if item.type == .VSPACE {
                // TODO: See if this also works right after starting
                // a new page (probably not).
                flush_current_line(*rs, page_info, line_start_indent_mpt, false);
                is_line_start = true;
                rs.next_char_y_pt -= item.vspace;
                print(*rs.current_page_text_cmds,
                    "  0 % Td\n",
                    -item.vspace,
                );
            } else if item.type == .HRULE {
                flush_current_line(*rs, page_info, line_start_indent_mpt, false);
                is_line_start = true;
                print(*rs.current_page_draw_cmds, #string END
  0.0 0.0 0.0 RG
  % % m
  % % l
  S
  END,
                    page_info.min_text_x_pt,
                    rs.next_char_y_pt,
                    page_info.max_text_x_pt,
                    rs.next_char_y_pt,
                );
            } else if item.type == .IMAGE {
                flush_current_line(*rs, page_info, line_start_indent_mpt, false);

                assert(item.image_index >= 0 && item.image_index < images.count, "PDF: Image index out of bounds.");
                image := images[item.image_index];

                print(*rs.current_page_text_cmds,
                    "  0 % Td\n",
                    -image.height,
                );
                rs.next_char_y_pt -= image.height;

                array_add_if_unique(*rs.currently_used_image_indices, item.image_index);
                print(*rs.current_page_draw_cmds, #string END
  q
    % 0 0 % % % cm
    /Im% Do
  Q
END,
                    image.width,
                    image.height,
                    page_info.min_text_x_pt,
                    rs.next_char_y_pt,
                    item.image_index+1,
                );
                #if PAGE_DEBUG_FLAGS & .IMAGES {
                    print(*rs.current_page_draw_cmds, #string END
  1.0 0.0 0.0 RG
  % % % % re
  S
END,
                        page_info.min_text_x_pt,
                        rs.next_char_y_pt,
                        image.width,
                        image.height,
                    );
                }
            } else
                assert(false);
        }
        flush_current_line(*rs, page_info, line_start_indent_mpt, false);
        flush_page(*pages, *rs);
    }

    pages_obj_number := pdf.next_object_number + 1;
    pdf_write_object(*pdf, tprint(#string END
<<
  /Type /Catalog
  /Pages % 0 R
>>
END, pages_obj_number));

    first_page_obj_number := pdf.next_object_number + 1 + 2*fonts.count + images.count;
    {
        builder: String_Builder;
        for pages
            print(*builder, "    % 0 R\n", first_page_obj_number + it_index);
        pdf_write_object(*pdf, tprint(#string END
<<
  /Type /Pages
  /Count %
  /Kids [
%  ]
>>
END, pages.count, builder_to_string(*builder)));
    }

    first_font_obj_number := pdf.next_object_number;
    first_font_descriptor_obj_number := pdf.next_object_number + fonts.count;
    for font, font_idx : fonts {
        glyph_widths_builder: String_Builder;
        for font.glyph_widths {
            if it_index != 0
                append(*glyph_widths_builder, " ");
            print_integer(*glyph_widths_builder, .{value=it});
        }

        pdf_write_object(*pdf, tprint(#string END
<<
  /Type /Font
  /Subtype /Type1
  /Name /F%
  /BaseFont /%
  /FirstChar 0
  /LastChar 255
  /Widths [ % ]
  /FontDescriptor % 0 R
>>
END,
            font_idx+1,
            font.name,
            builder_to_string(*glyph_widths_builder),
            first_font_descriptor_obj_number + font_idx),
        );
    }
    for font : fonts {
        pdf_write_object(*pdf, tprint(#string END
<<
  /Type /FontDescriptor
  /FontName /%
>>
END, font.name));
    }

    first_image_obj_number := pdf.next_object_number;
    for image, image_idx : images {
        pdf_write_stream_object(*pdf, image.data, tprint(#string END
  /Type /XObject
  /Subtype /Image
  /Width %
  /Height %
  /ColorSpace /DeviceRGB
  /BitsPerComponent 8
END,
            image.width,
            image.height,
        ));
    }

    first_content_obj_number := pdf.next_object_number + pages.count;
    for page, page_index : pages {
        fonts_builder: String_Builder;
        for page.dependencies.font_indices {
            print(*fonts_builder, "      /F% % 0 R\n", it+1, first_font_obj_number + it);
        }
        xobjects_builder: String_Builder;
        for page.dependencies.image_indices {
            print(*xobjects_builder, "      /Im% % 0 R\n", it+1, first_image_obj_number + it);
        }
        pdf_write_object(*pdf, tprint(#string END
<<
  /Type /Page
  /Contents % 0 R
  /MediaBox [ 0 0 % % ]
  /Parent % 0 R
  /Resources <<
    /Font <<
%    >>
    /XObject <<
%    >>
  >>
>>
END,
            first_content_obj_number + page_index,
            page_format.width, page_format.height,
            pages_obj_number,
            builder_to_string(*fonts_builder),
            builder_to_string(*xobjects_builder),
        ));
    }

    for pages {
        builder: String_Builder;
        append(*builder, it.contents);

        pdf_write_stream_object(*pdf, builder_to_string(*builder));
    }

    pdf_write_footer(*pdf);

    return builder_to_string(*pdf.builder);
}

#scope_file

Core_Font :: struct {
    name: string;
    // everything in font-space milli-pt
    underline_position: s32;
    underline_thickness: s32;
    glyph_widths: [256]s32;
}

CORE_FONTS :: Core_Font.[
    // https://github.com/jung-kurt/gofpdf/tree/master/font
    .{
        name = "Helvetica",
        underline_position = -100,
        underline_thickness = 50,
        glyph_widths = .[278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,355,556,556,889,667,191,333,333,389,584,278,333,278,278,556,556,556,556,556,556,556,556,556,556,278,278,584,584,584,556,1015,667,667,722,722,667,611,778,722,278,500,667,556,833,722,778,667,778,722,667,611,722,667,944,667,667,611,278,278,278,469,556,333,556,556,500,556,556,278,556,556,222,222,500,222,833,556,556,556,556,333,500,278,556,500,722,500,500,500,334,260,334,584,350,556,350,222,556,333,1000,556,556,333,1000,667,333,1000,350,611,350,350,222,222,333,333,350,556,1000,333,1000,500,333,944,350,500,667,278,333,556,556,556,556,260,556,333,737,370,556,584,333,737,333,400,584,333,333,333,556,537,278,333,333,365,556,834,834,834,611,667,667,667,667,667,667,1000,722,667,667,667,667,278,278,278,278,722,722,778,778,778,778,778,584,778,722,722,722,722,667,667,611,556,556,556,556,556,556,889,500,556,556,556,556,278,278,278,278,556,556,556,556,556,556,556,584,611,556,556,556,556,500,556,500],
    },
    .{
        name = "Helvetica-Bold",
        underline_position = -100,
        underline_thickness = 50,
        glyph_widths = .[278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,333,474,556,556,889,722,238,333,333,389,584,278,333,278,278,556,556,556,556,556,556,556,556,556,556,333,333,584,584,584,611,975,722,722,722,722,667,611,778,722,278,556,722,611,833,722,778,667,778,722,667,611,722,667,944,667,667,611,333,278,333,584,556,333,556,611,556,611,556,333,611,611,278,278,556,278,889,611,611,611,611,389,556,333,611,556,778,556,556,500,389,280,389,584,350,556,350,278,556,500,1000,556,556,333,1000,667,333,1000,350,611,350,350,278,278,500,500,350,556,1000,333,1000,556,333,944,350,500,667,278,333,556,556,556,556,280,556,333,737,370,556,584,333,737,333,400,584,333,333,333,611,556,278,333,333,365,556,834,834,834,611,722,722,722,722,722,722,1000,722,667,667,667,667,278,278,278,278,722,722,778,778,778,778,778,584,778,722,722,722,722,667,667,611,556,556,556,556,556,556,889,556,556,556,556,556,278,278,278,278,611,611,611,611,611,611,611,584,611,611,611,611,611,556,611,556],
    },
    .{
        name = "Helvetica-Oblique",
        underline_position = -100,
        underline_thickness = 50,
        glyph_widths = .[278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,355,556,556,889,667,191,333,333,389,584,278,333,278,278,556,556,556,556,556,556,556,556,556,556,278,278,584,584,584,556,1015,667,667,722,722,667,611,778,722,278,500,667,556,833,722,778,667,778,722,667,611,722,667,944,667,667,611,278,278,278,469,556,333,556,556,500,556,556,278,556,556,222,222,500,222,833,556,556,556,556,333,500,278,556,500,722,500,500,500,334,260,334,584,350,556,350,222,556,333,1000,556,556,333,1000,667,333,1000,350,611,350,350,222,222,333,333,350,556,1000,333,1000,500,333,944,350,500,667,278,333,556,556,556,556,260,556,333,737,370,556,584,333,737,333,400,584,333,333,333,556,537,278,333,333,365,556,834,834,834,611,667,667,667,667,667,667,1000,722,667,667,667,667,278,278,278,278,722,722,778,778,778,778,778,584,778,722,722,722,722,667,667,611,556,556,556,556,556,556,889,500,556,556,556,556,278,278,278,278,556,556,556,556,556,556,556,584,611,556,556,556,556,500,556,500],
    },
    .{
        name = "Helvetica-BoldOblique",
        underline_position = -100,
        underline_thickness = 50,
        glyph_widths = .[278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,278,333,474,556,556,889,722,238,333,333,389,584,278,333,278,278,556,556,556,556,556,556,556,556,556,556,333,333,584,584,584,611,975,722,722,722,722,667,611,778,722,278,556,722,611,833,722,778,667,778,722,667,611,722,667,944,667,667,611,333,278,333,584,556,333,556,611,556,611,556,333,611,611,278,278,556,278,889,611,611,611,611,389,556,333,611,556,778,556,556,500,389,280,389,584,350,556,350,278,556,500,1000,556,556,333,1000,667,333,1000,350,611,350,350,278,278,500,500,350,556,1000,333,1000,556,333,944,350,500,667,278,333,556,556,556,556,280,556,333,737,370,556,584,333,737,333,400,584,333,333,333,611,556,278,333,333,365,556,834,834,834,611,722,722,722,722,722,722,1000,722,667,667,667,667,278,278,278,278,722,722,778,778,778,778,778,584,778,722,722,722,722,667,667,611,556,556,556,556,556,556,889,556,556,556,556,556,278,278,278,278,611,611,611,611,611,611,611,584,611,611,611,611,611,556,611,556],
    },
    .{
        name = "Courier",
        underline_position = -100,
        underline_thickness = 50,
        glyph_widths = .[600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600],
    },
    .{
        name = "Courier-Bold",
        underline_position = -100,
        underline_thickness = 50,
        glyph_widths = .[600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600],
    },
    .{
        name = "Courier-Oblique",
        underline_position = -100,
        underline_thickness = 50,
        glyph_widths = .[600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600],
    },
    .{
        name = "Courier-BoldOblique",
        underline_position = -100,
        underline_thickness = 50,
        glyph_widths = .[600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600],
    },
    .{
        name = "Times-Roman",
        underline_position = -100,
        underline_thickness = 50,
        glyph_widths = .[250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,333,408,500,500,833,778,180,333,333,500,564,250,333,250,278,500,500,500,500,500,500,500,500,500,500,278,278,564,564,564,444,921,722,667,667,722,611,556,722,722,333,389,722,611,889,722,722,556,722,667,556,611,722,722,944,722,722,611,333,278,333,469,500,333,444,500,444,500,444,333,500,500,278,278,500,278,778,500,500,500,500,333,389,278,500,500,722,500,500,444,480,200,480,541,350,500,350,333,500,444,1000,500,500,333,1000,556,333,889,350,611,350,350,333,333,444,444,350,500,1000,333,980,389,333,722,350,444,722,250,333,500,500,500,500,200,500,333,760,276,500,564,333,760,333,400,564,300,300,333,500,453,250,333,300,310,500,750,750,750,444,722,722,722,722,722,722,889,667,611,611,611,611,333,333,333,333,722,722,722,722,722,722,722,564,722,722,722,722,722,722,556,500,444,444,444,444,444,444,667,444,444,444,444,444,278,278,278,278,500,500,500,500,500,500,500,564,500,500,500,500,500,500,500,500],
    },
    .{
        name = "Times-Bold",
        underline_position = -100,
        underline_thickness = 50,
        glyph_widths = .[250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,333,555,500,500,1000,833,278,333,333,500,570,250,333,250,278,500,500,500,500,500,500,500,500,500,500,333,333,570,570,570,500,930,722,667,722,722,667,611,778,778,389,500,778,667,944,722,778,611,778,722,556,667,722,722,1000,722,722,667,333,278,333,581,500,333,500,556,444,556,444,333,500,556,278,333,556,278,833,556,500,556,556,444,389,333,556,500,722,500,500,444,394,220,394,520,350,500,350,333,500,500,1000,500,500,333,1000,556,333,1000,350,667,350,350,333,333,500,500,350,500,1000,333,1000,389,333,722,350,444,722,250,333,500,500,500,500,220,500,333,747,300,500,570,333,747,333,400,570,300,300,333,556,540,250,333,300,330,500,750,750,750,500,722,722,722,722,722,722,1000,722,667,667,667,667,389,389,389,389,722,722,778,778,778,778,778,570,778,722,722,722,722,722,611,556,500,500,500,500,500,500,722,444,444,444,444,444,278,278,278,278,500,556,500,500,500,500,500,570,500,556,556,556,556,500,556,500],
    },
    .{
        name = "Times-Italic",
        underline_position = -100,
        underline_thickness = 50,
        glyph_widths = .[250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,333,420,500,500,833,778,214,333,333,500,675,250,333,250,278,500,500,500,500,500,500,500,500,500,500,333,333,675,675,675,500,920,611,611,667,722,611,611,722,722,333,444,667,556,833,667,722,611,722,611,500,556,722,611,833,611,556,556,389,278,389,422,500,333,500,500,444,500,444,278,500,500,278,278,444,278,722,500,500,500,500,389,389,278,500,444,667,444,444,389,400,275,400,541,350,500,350,333,500,556,889,500,500,333,1000,500,333,944,350,556,350,350,333,333,556,556,350,500,889,333,980,389,333,667,350,389,556,250,389,500,500,500,500,275,500,333,760,276,500,675,333,760,333,400,675,300,300,333,500,523,250,333,300,310,500,750,750,750,500,611,611,611,611,611,611,889,667,611,611,611,611,333,333,333,333,722,667,722,722,722,722,722,675,722,722,722,722,722,556,611,500,500,500,500,500,500,500,667,444,444,444,444,444,278,278,278,278,500,500,500,500,500,500,500,675,500,500,500,500,500,444,500,444],
    },
    .{
        name = "Times-BoldItalic",
        underline_position = -100,
        underline_thickness = 50,
        glyph_widths = .[250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,250,389,555,500,500,833,778,278,333,333,500,570,250,333,250,278,500,500,500,500,500,500,500,500,500,500,333,333,570,570,570,500,832,667,667,667,722,667,667,722,778,389,500,667,611,889,722,722,611,722,667,556,611,722,667,889,667,611,611,333,278,333,570,500,333,500,500,444,500,444,333,500,556,278,278,500,278,778,556,500,500,500,389,389,278,556,444,667,500,444,389,348,220,348,570,350,500,350,333,500,500,1000,500,500,333,1000,556,333,944,350,611,350,350,333,333,500,500,350,500,1000,333,1000,389,333,722,350,389,611,250,389,500,500,500,500,220,500,333,747,266,500,606,333,747,333,400,570,300,300,333,576,500,250,333,300,300,500,750,750,750,500,667,667,667,667,667,667,944,667,667,667,667,667,389,389,389,389,722,722,722,722,722,722,722,570,722,722,722,722,722,611,611,500,500,500,500,500,500,500,722,444,444,444,444,444,278,278,278,278,500,556,500,500,500,500,500,570,500,556,556,556,556,444,500,444],
    },
    .{
        name = "ZapfDingbats",
        underline_position = -100,
        underline_thickness = 50,
        glyph_widths = .[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,278,974,961,974,980,719,789,790,791,690,960,939,549,855,911,933,911,945,974,755,846,762,761,571,677,763,760,759,754,494,552,537,577,692,786,788,788,790,793,794,816,823,789,841,823,833,816,831,923,744,723,749,790,792,695,776,768,792,759,707,708,682,701,826,815,789,789,707,687,696,689,786,787,713,791,785,791,873,761,762,762,759,759,892,892,788,784,438,138,277,415,392,392,668,668,0,390,390,317,317,276,276,509,509,410,410,234,234,334,334,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,732,544,544,910,667,760,760,776,595,694,626,788,788,788,788,788,788,788,788,788,788,788,788,788,788,788,788,788,788,788,788,788,788,788,788,788,788,788,788,788,788,788,788,788,788,788,788,788,788,788,788,894,838,1016,458,748,924,748,918,927,928,928,834,873,828,924,924,917,930,931,463,883,836,836,867,867,696,696,874,0,874,760,946,771,865,771,888,967,888,831,873,927,970,918,0],
    },
];

pdf_write_header :: (pdf: *PDF) {
    append(*pdf.builder, "%PDF-2.0\n");
}

pdf_write_object :: (pdf: *PDF, contents: string) {
    array_add(*pdf.object_offsets, builder_string_length(*pdf.builder)+1);
    print(*pdf.builder, #string END
% 0 obj
%endobj
END, pdf.next_object_number, contents);
    pdf.next_object_number += 1;
}

pdf_write_stream_object :: inline (pdf: *PDF, contents: string, extra_dict_items: string = "") {
    pdf_write_object(pdf, tprint(#string END
<<
%  /Length %
>>
stream
%
endstream
END, extra_dict_items, contents.count, contents));
}

pdf_write_footer :: (pdf: *PDF) {
    append(*pdf.builder, "xref\n");
    xref_position := builder_string_length(*pdf.builder)+1;
    append(*pdf.builder, tprint(#string END
0 %
0000000000 65535 f 
END, pdf.next_object_number));
    for pdf.object_offsets {
        print_integer(*pdf.builder, .{value=it, minimum_digits=10});
        append(*pdf.builder, " 00000 n\n");
    }

    id_hash_hex: string;
    {
        // Just a random way to generate a unique ID
        h := fnv1a_hash(to_microseconds(current_time_monotonic()).(u64));
        for pdf.object_offsets
            h = fnv1a_hash(it.(u64), h=h);

        builder: String_Builder;
        print_integer(*builder, .{value=h, minimum_digits=16, base=16});
        print_integer(*builder, .{value=h, minimum_digits=16, base=16});
        id_hash_hex = builder_to_string(*builder);
    }
    append(*pdf.builder, tprint(#string END
trailer <<
  /Root 1 0 R
  /Size %
  /ID [<%><%>]
>>
startxref
%
END, pdf.next_object_number, id_hash_hex, id_hash_hex, xref_position));
    pdf.next_object_number += 1;
    append(*pdf.builder, "%%EOF\n");
}

#import "Basic";
#import "Hash";
#import "String";