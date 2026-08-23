#!/usr/bin/env bash
# Build resume.pdf and the Word fallback, then assert the properties that have
# silently broken before. Run this instead of calling Chrome and pandoc by hand.
set -euo pipefail
cd "$(dirname "$0")"

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
SRC_HTML="private/resume-print.html"
SRC_MD="private/resume.md"
PDF="resume.pdf"
DOCX="Edward-Vartanessian-Resume.docx"

echo "==> PDF"
"$CHROME" --headless --disable-gpu --no-pdf-header-footer \
  --print-to-pdf="$PDF" "file://$PWD/$SRC_HTML" 2>/dev/null

echo "==> DOCX"
CLEAN=$(mktemp -t resume-clean).md
# Strip the working notes: they are for Ed, not for a hiring manager.
sed -e '/^> \*\*Swap the head noun/,/^> sees both in one glance.*$/d' \
    -e '/^# Notes for Ed/,$d' \
    -e '/^> \*\*Why this framing/,/^> bullet \[FILL IN if shareable\]\.$/d' \
    "$SRC_MD" > "$CLEAN"
pandoc "$CLEAN" -f markdown -t docx -o "$DOCX"
rm -f "$CLEAN"

echo "==> Verify"
fail=0
# set -e would abort on the first failing assertion before it could be
# reported, so checks run with it off and report every failure together.
set +e
check() { # description, condition-already-evaluated-as-exit-code
  if [ "$2" -eq 0 ]; then printf '    ok    %s\n' "$1"
  else printf '    FAIL  %s\n' "$1"; fail=1; fi
}

TEXT=$(pdftotext "$PDF" -)

# The one that actually broke: a line-break hyphen rejoined this as
# "opentelemetrycollector-contrib", corrupting the search string for the
# rarest credential on the page.
grep -q 'opentelemetry-collector-contrib' <<<"$TEXT"; check "contrib string extracts intact" $?

# Styled text is not a link. This was 0 for months and nobody could click through.
ANNOTS=$(strings "$PDF" | grep -c '/Annots' || true)
[ "$ANNOTS" -gt 0 ]; check "PDF carries link annotations ($ANNOTS)" $?

# Claims that must survive an edit.
for term in Kubernetes Swift Aurora 33393 Drizzle approvers passwordless 'U.S. citizen'; do
  grep -qi -- "$term" <<<"$TEXT"; check "present: $term" $?
done

# Working notes must never reach the artifacts.
! grep -qiE 'FILL IN|Notes for Ed|Why this framing|Swap the head noun' <<<"$TEXT"
check "no working notes leaked into PDF" $?

PAGES=$(pdfinfo "$PDF" | awk '/^Pages/{print $2}')
[ "$PAGES" -le 2 ]; check "fits 2 pages (is $PAGES)" $?

DOCX_TEXT=$(python3 -c "
import zipfile,re,sys
x=zipfile.ZipFile('$DOCX').read('word/document.xml').decode('utf8')
print(re.sub(r'<[^>]+>','',x))")
! grep -qiE 'FILL IN|Notes for Ed|Why this framing|Swap the head noun' <<<"$DOCX_TEXT"
check "no working notes leaked into DOCX" $?

echo
[ "$fail" -eq 0 ] && echo "All checks passed." || { echo "Build produced a bad artifact."; exit 1; }
