#!/usr/bin/env bash
# Render a styled HTML doc to PDF via headless Chrome (clickable links preserved).
#   ./scripts/build_doc_pdf.sh path/to/doc.html
set -euo pipefail
cd "$(dirname "$0")/.."

html="${1:?usage: build_doc_pdf.sh <doc.html>}"
[ -f "$html" ] || { echo "no $html (run: ruby scripts/build_doc.rb ...)" >&2; exit 1; }
pdf="${html%.html}.pdf"
abs="$(cd "$(dirname "$html")" && pwd)/$(basename "$html")"

CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
[ -x "$CHROME" ] || { echo "Chrome not found at $CHROME" >&2; exit 1; }

"$CHROME" --headless=new --disable-gpu --no-pdf-header-footer \
  --print-to-pdf="$pdf" "file://$abs" >/dev/null 2>&1

[ -f "$pdf" ] && echo "wrote $pdf ($(du -h "$pdf" | cut -f1))" || { echo "PDF generation failed" >&2; exit 1; }
