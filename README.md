# Interpreter

On-device document and text translation for macOS. Interpreter is an OMC/ActionUI shell applet that drives a bundled `mlx-agent` running a TranslateGemma (MLX) model - all translation happens locally, no network once a model is downloaded.

Two modes:

- Text window: type or paste text, pick From/To languages, translate.
- Document window: pick/drop a document; Interpreter converts it to plain text, translates it, and writes a `<name>-translated.txt` next to the original.

## Supported document types

Document translation converts the input to plain UTF-8 text (see `convert_to_plain_text` in `Contents/Resources/Scripts/lib.interp.sh`) and translates that text. Most formats go through `textutil`; PDF goes through the bundled `pdftext` helper (PDFKit), because `textutil` cannot read PDF.

| Format | Typical extensions | UTI | Via |
| --- | --- | --- | --- |
| Plain text | `.txt`, and other `public.text` (source code, `.csv`, `.xml`) | `public.text` | textutil |
| PDF (text-based) | `.pdf` | `com.adobe.pdf` | pdftext (PDFKit) |
| Rich Text | `.rtf` | `public.rtf` | textutil |
| Rich Text with attachments | `.rtfd` | `com.apple.rtfd` | textutil |
| HTML | `.html`, `.htm` | `public.html` | textutil |
| Web archive | `.webarchive` | `com.apple.webarchive` | textutil |
| Microsoft Word 97-2004 | `.doc` | `com.microsoft.word.doc` | textutil |
| Microsoft Word (OOXML) | `.docx` | `org.openxmlformats.wordprocessingml.document` | textutil |
| Word XML | `.xml` (WordML) | `com.microsoft.word.wordml` | textutil |
| OpenDocument Text | `.odt` | `org.oasis-open.opendocument.text` | textutil |

Notes:

- Encoding: output is always UTF-8. UTF-8 plain text passes through unchanged; UTF-16 (with BOM, common from Windows) is transcoded correctly. A legacy single-byte plain-text file with no BOM (e.g. ISO-8859-1 / Windows-1252) may be mis-decoded - this is a `textutil` limitation (its input-encoding guess), not something the app can reliably detect. Save such files as UTF-8 first.
- How files reach the document window:
  - File > Open filters the panel to the UTIs above (`CHOOSE_FILE_DIALOG.ALLOWED_CONTENT_TYPES` in `Command.json`).
  - Drag-and-drop onto the app, "Open With", and the "Translate with Interpreter" Finder service (`NSSendFileTypes` in `Info.plist`) accept these types and let the converter decide. A file it cannot read raises a "Can't read this document" alert; a readable-but-empty file raises "Nothing to translate".

### PDF specifics and limitations

PDF text is extracted with `Contents/Support/pdftext`, a small PDFKit tool built from `Tools/pdftext.swift` (see Building). It is fast (about 1M characters across 300+ pages in ~1.2s) and preserves Unicode; left-to-right scripts (Latin, CJK, Cyrillic, Greek, etc.) come out in correct reading order. Know the limits:

- Scanned / image-only PDFs have no text layer and yield nothing - Interpreter reports "Can't read this document". (A future Vision OCR fallback could handle these; not implemented.)
- PDFs whose fonts lack a usable ToUnicode map (some tax/form PDFs, custom-encoded fonts) extract as placeholder-glyph garbage. `convert_to_plain_text` runs a garbage gate (`pdf_text_is_usable`) that rejects output dominated by a single character, so these also cleanly report "Can't read this document" rather than translating junk.
- Right-to-left scripts (Arabic, Hebrew) are extracted in visual, not logical, order - translating from an RTL-language PDF may be garbled. This is a PDFKit limitation.
- Line breaks fall at each visual line, not per paragraph, so paragraphs arrive hard-wrapped. Translatable as-is; a reflow pass is a possible future improvement.

## Not supported: Apple Pages

`textutil` cannot read a `.pages` file (it reports "The file isn't in the correct format."), and dropping one raises "Can't read this document".  
User needs to export Pages document into one of the supported formats.

## Building

The runtime binaries under `Contents/Support` are git-excluded build artifacts, assembled by `update_interpreter.sh`:

- `mlx-agent` (+ its MLX resource bundles) - built from the separate `mlx-agent` repo via `xcodebuild` (Metal shaders), deployed to `Contents/Support/MLX/`.
- `pdftext` - compiled from `Tools/pdftext.swift` with `swiftc` (system frameworks only, no Metal), deployed to `Contents/Support/pdftext`.

Both are ad-hoc codesigned and the app is re-sealed by the script. Run `./update_interpreter.sh` (see `--help` for `--release`, `--arch`, `--skip-build`, `--identity`).

## Layout

- `Interpreter.app/Contents/Resources/Scripts/` - the OMC command handlers and shared libraries (`lib.interp.sh`, `lib.interp.models.sh`). POSIX `/bin/sh` (macOS bash 3.2); validate with `sh -n`.
- `Interpreter.app/Contents/Resources/Command.json` - OMC command definitions (windows, dialogs, services).
- `Interpreter.app/Contents/Support/MLX/mlx-agent` - the bundled translation engine (map broker + model loader).
- `Interpreter.app/Contents/Support/pdftext` - the bundled PDF text-extraction helper.
- `Tools/pdftext.swift` - source for the `pdftext` helper.
- Application support at runtime: `~/Library/Application Support/Interpreter/` (`Models/`, `Sessions/`, `Cache/`, `Downloads/`).

## Requirements

- macOS 14.6 or later.
- A downloaded TranslateGemma model (the app offers a RAM-aware chooser on first run).
