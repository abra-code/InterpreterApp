# Interpreter
![Interpreter Icon](Icon/Interpreter-macOS-256x256@1x.png)


On-device document and text translation for macOS. Interpreter is an OMC/ActionUI shell applet that drives bundled local inference engines - [`mlx-agent`](https://github.com/abra-code/mlx-agent) (MLX) for TranslateGemma and MiLMMT-46 models, and `llama.cpp` for GGUF models such as Hy-MT2 - behind a RAM-aware model chooser. All translation happens locally.

Two modes:

- Text window: type or paste text, pick From/To languages, translate.
- Document window: pick/drop a document; Interpreter converts it to plain text, translates it, and writes a `<name>-translated.txt` next to the original.

## On-device by design

Everything the app does to your text and documents runs on this Mac:

- Translation: the models are downloaded once (from Hugging Face, via the model chooser) and run locally on MLX or the bundled `llama.cpp`. No text ever leaves the machine.
- Document conversion: `textutil` and the bundled `pdfutil` are local tools.
- OCR of scanned PDFs: Apple's Vision framework, which recognizes text entirely on-device - verifiable by running the extraction under a network-denying sandbox (`sandbox-exec -p '(version 1)(allow default)(deny network*)' ...`), where it works unchanged.

One disclaimer on OCR: Vision's per-language recognizer models are macOS assets. Common languages ship with the OS, but the first use of a less common recognition language on a fresh system may trigger a one-time asset download from Apple - a model coming down, never your document going up. Offline with missing assets, that page's hinted recognition fails and Interpreter retries the page with the recognizers already on the machine (auto-detect).

## Supported document types

Document translation converts the input to plain UTF-8 text (see `convert_to_plain_text` in `Contents/Resources/Scripts/lib.interp.sh`) and translates that text. Most formats go through `textutil`; PDF goes through the bundled `pdfutil` (PDFKit), because `textutil` cannot read PDF.

| Format | Typical extensions | UTI | Via |
| --- | --- | --- | --- |
| Plain text | `.txt`, and other `public.text` (source code, `.csv`, `.xml`) | `public.text` | textutil |
| PDF | `.pdf` | `com.adobe.pdf` | pdfutil (PDFKit; Vision OCR for scanned pages) |
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

PDF text is extracted page by page with the bundled `pdfutil` (github.com/abra-code/pdfutil): one `text` pass reads the text layer, and any page with no text is recognized individually with Vision OCR (`pdfutil ocr`), hinted with the selected From language. The pages are stitched back in document order, so:

- Scanned / image-only PDFs translate via OCR (on-device - see above). OCR is slower than text extraction (Vision rasterizes and reads each page); the status line counts pages and Stop cancels at any point, losing at most one page of work.
- Mixed documents - digital text with scanned inserts (a signed page, a scanned appendix) - lose nothing: text pages are extracted verbatim, scanned pages are OCR'd.
- A PDF whose entire text layer is unusable (fonts without a ToUnicode map extract as placeholder-glyph garbage; the `pdf_text_is_usable` gate catches this) is OCR'd wholesale instead of translating junk.
- Not handled: text trapped inside images on pages that ALSO have a text layer. Such pages contribute their text layer only - region-aware merging would need support in `pdfutil` itself.
- Right-to-left scripts (Arabic, Hebrew) are extracted in visual, not logical, order - translating from an RTL-language PDF may be garbled. This is a PDFKit limitation.
- Line breaks fall at each visual line, not per paragraph, so paragraphs arrive hard-wrapped. Translatable as-is; a reflow pass is a possible future improvement.

## Source-language identification (`langid`)

`Tools/langid` is a small first-party helper that names the language of a document, so the From language can be detected instead of asked for. It is built into `Contents/Support/langid` by `update_interpreter.sh` and is usable from any script:

```sh
lang=$("$SUPPORT_DIR/langid" --file "$plain_text" --min-confidence 0.5) || lang=""
```

It prints the BCP-47 primary subtag alone (`pl`), or nothing with exit 1 when it will not commit to an answer. `--json` gives every candidate with its probability.

It uses NaturalLanguage's `NLLanguageRecognizer`, not a language model. That was measured rather than assumed: Apple's on-device Foundation Models system model answers the same question with a constrained schema and agreed on every language tried, but took 260-630 ms against 3-4 ms here, requires macOS 26 with Apple Intelligence enabled, and returns a bare label instead of a probability distribution. Where a purpose-built framework already answers the question, it beats the LLM on speed, calibration and availability.

Two behaviors worth knowing before relying on it:

- **The recognizer is dominated by the start of its input.** Measured: 200 characters of English followed by 19,600 characters of Spanish was reported as English, and supplying more text changed nothing. `langid` therefore analyzes several windows spread across the document and averages them, so a foreign-language title, byline or quotation cannot decide the answer alone. `--max-chars` bounds reading (so a huge file is not pulled into memory), not analysis.
- **Markup and code degrade it.** Before the windowing above, this project's own English README was identified as Dutch, because its opening is mostly markdown, paths and URLs. Translation already converts to plain text before this runs, which removes most of that, but a document that is largely code or tables is still a poor input.

## Not supported: Apple Pages

`textutil` cannot read a `.pages` file (it reports "The file isn't in the correct format."), and dropping one raises "Can't read this document".  
User needs to export Pages document into one of the supported formats.

## Building

The runtime binaries under `Contents/Support` are git-excluded build artifacts, assembled by `update_interpreter.sh`:

- `mlx-agent` (+ its MLX resource bundles) - built from the separate `mlx-agent` repo (github.com/abra-code/mlx-agent, Apache 2.0) via `xcodebuild` (Metal shaders), deployed to `Contents/Support/MLX/` with its LICENSE beside it, alongside a `mlx-agent.THIRD-PARTY-NOTICES.txt` generated by that repo's `tools/generate_third_party_notices.sh` (the binary statically links ~18 Swift packages, and three of them ship the resource bundles that travel with it).
- `pdfutil` - built from the separate `pdfutil` repo (github.com/abra-code/pdfutil, Apache 2.0) via its own `build.sh` (plain `swiftc`, system frameworks only), deployed to `Contents/Support/pdfutil` with its LICENSE beside it.
- `langid` - built from `Tools/langid` in THIS repo (see below) via its own `build.sh`, deployed to `Contents/Support/langid`. First-party, so it ships no third-party notice.
- `llama.cpp` (optional, for GGUF models) - a pinned upstream release provisioned with `--with-llama`, deployed to `Contents/Support/Llama.cpp/`.

Before signing, the script checks that every bundled third-party payload has its license notice beside it and refuses to continue otherwise - `mlx-agent` and the MLX resource bundles, `pdfutil`, and `Contents/Support/Llama.cpp` each have to carry one.

The app is Apple Silicon only: the script thins every universal Mach-O in the bundle (the OMC executable and Abracode.framework arrive universal from the AppletBuilder template) to the target arch before ad-hoc codesigning and re-sealing the app. Run `./update_interpreter.sh` (see `--help` for `--release`, `--arch`, `--skip-build`, `--identity`, `--with-llama`).

## Layout

- `Interpreter.app/Contents/Resources/Scripts/` - the OMC command handlers and shared libraries (`lib.interp.sh`, `lib.interp.models.sh`). POSIX `/bin/sh` (macOS bash 3.2); validate with `sh -n`.
- `Interpreter.app/Contents/Resources/Command.json` - OMC command definitions (windows, dialogs, services).
- `Interpreter.app/Contents/Resources/models.catalog.tsv` - the model families and variants the RAM-aware chooser curates.
- `Interpreter.app/Contents/Support/MLX/mlx-agent` - the bundled translation engine (map broker + model loader; also fronts llama-server for GGUF models).
- `Interpreter.app/Contents/Support/Llama.cpp/` - the bundled llama.cpp engine (GGUF models).
- `Interpreter.app/Contents/Support/pdfutil` - the bundled PDF toolbox (text extraction + OCR).
- `Interpreter.app/Contents/Support/langid` - source-language identification (see `Tools/langid`).
- Application support at runtime: `~/Library/Application Support/Interpreter/` (`Models/`, `Sessions/`, `Cache/`, `Downloads/`).

## Requirements

- An Apple Silicon Mac (the app and its engines are arm64-only) running macOS 14.6 or later.
- A downloaded translation model (the app offers a RAM-aware chooser on first run; models are curated per machine from the TranslateGemma, MiLMMT-46, and Hy-MT2 families).
