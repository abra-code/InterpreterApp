// pdftext - extract a PDF's text layer as UTF-8 on stdout.
//
// Part of Interpreter.app. textutil cannot read PDF (it misreads the raw bytes as plain text), so
// convert_to_plain_text in lib.interp.sh routes .pdf inputs here instead. Uses PDFKit, linking only
// system frameworks (PDFKit, Foundation) that are present on every supported macOS - no external
// dependencies, mirroring how the bundled mlx-agent is built and shipped in Contents/Support.
//
// Contract: on success, exit 0 and write the extracted text to stdout. On failure, exit non-zero
// and write nothing to stdout (a diagnostic goes to stderr) - the file cannot be opened, is locked,
// or has no text layer (scanned/image-only PDF). The caller (convert_to_plain_text) additionally
// applies a garbage gate for PDFs whose fonts lack a usable ToUnicode map.
//
// Known limitations (documented in README.md): right-to-left scripts (Arabic, Hebrew) come out in
// visual, not logical, order; line breaks fall at each visual line rather than per paragraph;
// scanned/image PDFs yield no text (would need Vision OCR).

import Foundation
import PDFKit

let args = CommandLine.arguments
guard args.count > 1 else {
    FileHandle.standardError.write(Data("usage: pdftext <file.pdf>\n".utf8))
    exit(2)
}

let url = URL(fileURLWithPath: args[1])
guard let doc = PDFDocument(url: url) else {
    FileHandle.standardError.write(Data("pdftext: cannot open PDF\n".utf8))
    exit(1)
}
if doc.isLocked {
    // Password-protected with no password supplied: nothing readable.
    FileHandle.standardError.write(Data("pdftext: PDF is locked\n".utf8))
    exit(1)
}
guard let text = doc.string, !text.isEmpty else {
    // No text layer (image-only/scanned) or an empty document.
    FileHandle.standardError.write(Data("pdftext: no extractable text\n".utf8))
    exit(1)
}
FileHandle.standardOutput.write(Data(text.utf8))
exit(0)
