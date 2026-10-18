# neodocs

**PDF, Word, Excel, CSV and Parquet in one tool.** Look inside documents, convert them, join and cut PDFs, take out the text and the
pictures, OCR scans, shrink them and strip the metadata, with nothing to install: no `qpdf`, `pdftotext`, `pandoc` or Office.

```
neodocs info|text|convert|merge|split|images|strip|ocr|shrink PATH... [options]
```

`PATH` is a file or a folder (`-r` goes into folders). Anything that is not a document is counted and left alone. Nothing is
installed at run time: PDFs, images, text documents and OCR use Apple's frameworks (PDFKit, Vision, AppKit); spreadsheets, Word
files and Parquet are read and written by the program itself.

## Commands

| command | does |
|---|---|
| `info` | what is in each file: format, pages, sheets or rows, size, date, title; notes for what matters (encrypted, scanned) |
| `text` | the text, on stdout (so it works in a pipe), or in files with `--out` |
| `convert` | change the format (`--to`) |
| `merge` | join PDFs and pictures into one PDF (`--out file`) |
| `split` | cut pages out of a PDF (`--pages 3-7,9`, `--each`, `--every n`) |
| `images` | take the pictures out of a PDF, as they are stored (JPEG stays the same bytes); `--min n` skips small ones |
| `strip` | take the author, the dates and the history out (`name-clean.ext`) |
| `ocr` | make a scanned PDF (or picture) searchable (`name-ocr.pdf`) with Apple's Vision; `--lang tr,en` |
| `shrink` | make a scanned PDF smaller (`name-small.pdf`); `--dpi`, `--quality` |

## Formats for `convert --to`

| from | to |
|---|---|
| `pdf` | `txt docx rtf odt html md pages`, and `png jpg heic tiff` (one picture per page, `--dpi`, default 150) |
| `docx rtf odt html md txt` | each other, `pdf`, `pages` |
| `csv tsv json jsonl xlsx parquet` | each other, `md html`, `numbers` |
| `xlsx` | also `pdf` |
| `pptx` | `pdf txt md key` |
| `pages` | `pdf docx rtf odt html md txt` |
| `numbers` | `pdf xlsx csv tsv json jsonl parquet md html` |
| `key` | `pdf pptx txt md` |

A PDF becomes a text flow: the words, the headings (from the size of the type), the lists and the paragraphs (the lines of a
paragraph are joined again), in the order PDFKit reads them. The layout, the columns, the tables and the pictures are not
carried. A scan has no text: `neodocs` says so and points to `ocr`, which makes it searchable first.

Pages, Numbers and Keynote files (both ways), and `pptx`/`xlsx` to PDF, are converted by the Apple apps, driven through `osascript`.
The apps open a Word, Excel or PowerPoint file; the other formats are written as one of these first (`odt`, `html`, `md`, `txt` and a PDF's text as `docx`, `csv`, `tsv`, `json`, `jsonl` and `parquet` as `xlsx`). A conversion that makes no sense (`docx` to `numbers`) is refused; for a Pages, Numbers or Keynote file with no route of ours the message says to open it in the app and use File > Export To.
The app is started out of sight if it was not running and quit again afterwards. The first time an app starts it may show a
"What's New" window that waits for a click; `neodocs` gives up after 120 seconds and says so. Version 15 of the apps is used
when installed, else version 14. `--app` lets Pages make the PDF of a Word file (more faithful than our layout).

## Tables

CSV (delimiter found from the first lines, RFC 4180 quotes, UTF-8, UTF-16 and Windows-1254 recognised), TSV, JSON, JSONL, XLSX
and Parquet read and write each other. The first row is the header unless `--no-header`. `--sheet name` picks an Excel sheet,
`--delimiter c` fixes the delimiter, `--excel` writes a `;`-separated CSV with a BOM, which Excel opens as it is, `--as-text` keeps
every value as text (so `007` stays `007`). Formulas are not calculated (the cached value is used). Parquet is read and written by
the compiled-in carquet library: flat tables, Snappy, row groups of 100,000 rows.

## Text documents

`docx` is read by our own reader (styles, headings, lists with their numbers, tables with merged cells, pictures, links, footnotes,
text boxes; tracked changes are accepted and said). `rtf`, `odt`, `doc` and `html` are read by the system. Writing: `docx` is ours,
`rtf odt html` the system's, `txt` and `md` ours, `pdf` is laid out by AppKit. The PDF is a plain, readable layout, not Word's.

## PDF

Merging, splitting, counting pages, `strip` and `images` read and write the structure of the file themselves and copy the pages
as they are (xref tables and streams, object streams, incremental updates). A file the reader does not take (damaged, encrypted
with a password) is handed to PDFKit. `NEODOCS_NO_FAST=1` forces PDFKit; `NEODOCS_TRACE=1` says why the fast path declined.
`strip` copies the whole document without the information dictionary, XMP packets, `PieceInfo`, `LastModified`, thumbnails and
the document ID.

## Options

`--pages list` (`3`, `3-7`, `5-`, `1,4,6-8`), `--out dir`, `--trash-original`, `--keep-dates`, `-n`/`--dry-run`, `--json`, `-v`,
`--plain`. Choosing files: `--larger`, `--smaller`, `--since`, `--before`, `--pages-over n`, `--format list`, `-r`, `--download`.
`info --sort name|size|modified|pages|format`, `--reverse`.

A result never overwrites a file that is there: the name is taken, skipped and said.

## Examples

```sh
neodocs info ~/Documents -r --sort pages
neodocs text report.pdf | grep -i total
neodocs split book.pdf --pages 12-20
neodocs merge cover.pdf scan1.jpg scan2.jpg --out file.pdf
neodocs images brochure.pdf --min 200
neodocs convert slides.pdf --to png --dpi 200
neodocs convert report.docx --to pdf
neodocs convert sales.xlsx --to parquet
neodocs text data.csv --to jsonl | jq .name
neodocs strip report.docx --trash-original
neodocs ocr scan.pdf --lang tr,en
neodocs shrink scan.pdf --dpi 150
```

## Limits

- A Word document is laid out by us, not by Word: headers and footers, columns, wrapped text and fields of a complex file do not
  look as in Word; comments are not carried; for a faithful PDF use `--app`.
- JBIG2 and CCITT pictures (old fax-style scans) cannot be taken out of a PDF. `xls` and `ppt` are not read.
- `shrink` changes only pages that are one big picture (a scan); it does not touch photographs on a page with text.
- The text layer from `ocr` and `shrink` is a recognition of the picture and can be wrong where the print is poor.
- Hostile files are held to limits: a page is drawn with at most 150 million pixels; a spreadsheet sheet holds at most 50 million
  cells; XML nested deeper than 256 levels, zip archives that would inflate beyond 4 GiB and Parquet footers with absurd sizes are
  refused as damaged files.
