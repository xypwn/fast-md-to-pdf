main :: () {
    opt_watch := false;
    in_file_path: string;
    out_file_path: string;

    args := get_command_line_arguments();
    if args.count > 0 {
        args.data += 1;
        args.count -= 1;
    }
    for arg : args {
        if arg.count >= 1 && arg[0] == #char "-" {
            if arg == {
                case "-watch";
                    opt_watch = true;
                case;
                    print_usage();
                    return;
            }
        } else {
            if in_file_path == "" {
                in_file_path = arg;
            } else if out_file_path == "" {
                out_file_path = arg;
            } else {
                print_usage();
                return;
            }
        }
    }
    if in_file_path == "" {
        print_usage();
        return;
    }
    if out_file_path == ""
        out_file_path = path_strip_extension(in_file_path);
    if out_file_path == in_file_path {
        print("Input and output file cannot be the same.\n");
        return;
    }
    {
        _, has_ext := path_extension(out_file_path);
        if !has_ext {
            out_file_path = sprint("%.pdf", out_file_path); // we leak dat shit
        }
    }

    {
        gen_time, ok := do_convert_md_to_pdf(in_file_path, out_file_path,, temp);
        if ok {
            print("Output saved to %. Generation took %ms.\n", out_file_path, gen_time*1000);
        } else {
            print("Error generating PDF.\n");
        }
    }
    reset_temporary_storage();
    
    if opt_watch {
        print("Watching for changes in %.\n", in_file_path);
        watcher: File_Watcher;
        if !init(
            *watcher,
            (watcher: *File_Watcher(void), change: *File_Change, data: *void) {},
            events_to_watch = .ADDED | .MODIFIED | .MOVED,
            merge_window_seconds = 0.01, // 0 seems to just make it not work
        ) {
            print("Could not initialize watcher.\n");
            return;
        }
        defer deinit(watcher);

        {
            in_path_abs, ok := get_absolute_path(in_file_path);
            if !ok {
                print("Could not get absolute path for %.\n", in_file_path);
                return;
            }
            if !add_directories(*watcher, path_strip_filename(in_path_abs)) {
                print("Could not watch file %.\n", in_file_path);
                return;
            }
        }

        POLL_INTERVAL_MILLISECONDS :: 100;
        // Once a change gets detected, we wait MERGE_WINDOW_MILLISECONDS ms,
        // ignoring any further events fired. Only then we actually generate
        // the new PDF.
        MERGE_WINDOW_MILLISECONDS :: 200;

        while true {
            process_changes(*watcher);

            in_file_changed := false;
            for watcher.changes {
                if !file_exists(it.full_path)
                    continue;
                if !file_exists(in_file_path)
                    continue;
                changed_path_abs := get_absolute_path(it.full_path);
                in_path_abs := get_absolute_path(in_file_path);
                if changed_path_abs == in_path_abs {
                    in_file_changed = true;
                    break;
                }
            }
            if in_file_changed {
                print("Change detected...");
                sleep_milliseconds(MERGE_WINDOW_MILLISECONDS);
                process_changes(*watcher); // swallow any new events
                {
                    gen_time, ok := do_convert_md_to_pdf(in_file_path, out_file_path,, temp);
                    if ok {
                        print("new output saved to %. Generation took %ms.\n", out_file_path, gen_time*1000);
                    } else {
                        print("Error generating PDF.\n");
                    }
                }
            }

            sleep_milliseconds(POLL_INTERVAL_MILLISECONDS);

            reset_temporary_storage();
        }
    }
}

print_usage :: () {
    print("Usage: fast-md-to-pdf input_file.md [output_file[.pdf]] [-watch]\n");
}

do_convert_md_to_pdf :: (in_file_path: string, out_file_path: string) -> generation_time_seconds: float64, ok: bool {
    t_start := seconds_since_init();

    file, ok := read_entire_file(in_file_path);
    if !ok {
        print("Failed to open input file %.\n", in_file_path);
        return 0, false;
    }

    pdf_doc := convert_md_to_pdf(file);
    if !write_entire_file(out_file_path, pdf_doc) {
        print("Failed to open output file %.\n", out_file_path);
        return 0, false;
    }

    generation_time_seconds := seconds_since_init() - t_start;

    return generation_time_seconds, true;
}

convert_md_to_pdf :: (md_text: string) -> pdf_document: string {
    md_document := Md.parse(md_text);
    #if DEBUG_PRINT_TOKENS {
        print("Tokens:\n");
        for token : md_document.tokens {
            if token.type == .CHAR {
                c := "EOF";
                if token.char.char != -1
                    c = to_string(*token.char.char.(u8), 1);
                print("'%' %\n", c, token.char);
            } else if token.type == .LINE_BREAK
                print("% %\n", token.type, token.line_break);
            else
                print("%\n", token.type);
        }
    }

    pdf_items: [..]Pdf.Item;
    {
        PDF_Builder :: struct {
            last_was_monospace: bool;
            last_char_modifiers: Md.Char_Modifiers;

            current_words:  [..]Pdf.Item.Text.Word;
            current_blocks: [..]Pdf.Item.Text.Word.Block;
            current_block:  String_Builder;
        }

        using pdf_builder: PDF_Builder;

        flush_current_block :: (using pdf_builder: *PDF_Builder) {
            if builder_string_length(*current_block) == 0
                return;
            
            font_size: s32;
            if last_char_modifiers & .HEADING_BITS == {
                case 0;   font_size = 12;
                case .H1; font_size = 32;
                case .H2; font_size = 26;
                case .H3; font_size = 22;
                case .H4; font_size = 18;
                case .H5; font_size = 16;
                case .H6; font_size = 14;
            }

            text_rise: s32;
            if last_char_modifiers & .SCRIPT_BITS == {
                case .SUBSCRIPT;
                    text_rise = -font_size/8;
                    font_size = 2*font_size/3;
                case .SUPERSCRIPT;
                    text_rise = font_size/3;
                    font_size = 2*font_size/3;
            }

            font_name: string;
            if last_char_modifiers & (.ITALIC | .BOLD | .MONOSPACE) == {
                case 0;                             font_name = "Helvetica";
                case .ITALIC;                       font_name = "Helvetica-Oblique";
                case .BOLD;                         font_name = "Helvetica-Bold";
                case .ITALIC | .BOLD;               font_name = "Helvetica-BoldOblique";
                case .MONOSPACE;                    font_name = "Courier";
                case .MONOSPACE | .ITALIC;          font_name = "Courier-Oblique";
                case .MONOSPACE | .BOLD;            font_name = "Courier-Bold";
                case .MONOSPACE | .ITALIC | .BOLD;  font_name = "Courier-BoldOblique";
                case;                               assert(false);
            }

            array_add(*current_blocks, .{
                font      = font_name,
                font_size = font_size,
                rise      = text_rise,
                text      = builder_to_string(*current_block)
            });
        }

        flush_current_word :: (using pdf_builder: *PDF_Builder) {
            flush_current_block(pdf_builder);

            array_add(*current_words, .{
                blocks          = current_blocks,
            });
            {
                empty: [..]Pdf.Item.Text.Word.Block;
                current_blocks = empty;
            }
        }

        flush_current_item :: (using pdf_builder: *PDF_Builder, pdf_items: *[..]Pdf.Item) {
            flush_current_word(pdf_builder);

            array_add(pdf_items, .{
                type = .TEXT,
                text = .{
                    spread_words = !last_was_monospace,
                    words = current_words,
                },
            });
            {
                empty: [..]Pdf.Item.Text.Word;
                current_words = empty;
            }
        }

        for token : md_document.tokens {
            if #complete token.type == {
                case .ERROR;
                    assert(false);
                case .CHAR;
                    is_monospace := token.char.modifiers & .MONOSPACE > 0;
                    if is_monospace != last_was_monospace
                        flush_current_item(*pdf_builder, *pdf_items);
                    if token.char.modifiers != last_char_modifiers
                        flush_current_block(*pdf_builder);
                    last_char_modifiers = token.char.modifiers;
                    last_was_monospace = is_monospace;
                    append(*current_block, token.char.char);
                case .WORD_BREAK;
                    flush_current_word(*pdf_builder);
                case .LINE_BREAK;
                    flush_current_item(*pdf_builder, *pdf_items);
                    array_add(*pdf_items, .{type = .NEWLINE});
                    {
                        prev_mods := token.line_break.previous_modifiers;
                        heading_bits := prev_mods & .HEADING_BITS;
                        if heading_bits {
                            if heading_bits == .H1 || heading_bits == .H2 {
                                array_add(*pdf_items, .{type = .VSPACE, vspace = 10});
                                array_add(*pdf_items, .{type = .HRULE});
                            } else {
                                array_add(*pdf_items, .{type = .VSPACE, vspace = 3});
                            }
                        } else {
                            array_add(*pdf_items, .{type = .VSPACE, vspace = 4});
                        }
                    }
                case .HORIZONTAL_RULE;
                    flush_current_item(*pdf_builder, *pdf_items);
                    array_add(*pdf_items, .{type = .VSPACE, vspace = 8});
                    array_add(*pdf_items, .{type = .HRULE});
                    array_add(*pdf_items, .{type = .VSPACE, vspace = 8});
                case .IMAGE;
                    // TODO
            }
        }
        flush_current_item(*pdf_builder, *pdf_items);
    }

    return Pdf.write(.{
        dimensions    = Pdf.A4,
        margin_left   = 72,
        margin_right  = 72,
        margin_top    = 72,
        margin_bottom = 72,
    }, pdf_items/*, images=doc_images*/);
}

#scope_file

DEBUG_PRINT_TOKENS :: false;

Md  :: #import,file "markdown_parser.jai";
Pdf :: #import,file "pdf_writer.jai"(PAGE_DEBUG_FLAGS=.NONE);
#import "Basic";
#import "File";
#import "File_Utilities";
#import "File_Watcher";
#import "String";
