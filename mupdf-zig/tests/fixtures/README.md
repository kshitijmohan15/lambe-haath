# Test Fixtures

Binary fixtures used by mupdf-zig tests. Regenerate from a clean shell:

## `sample-10pages.pdf` — 10 blank Letter-size pages

```bash
mkdir -p /tmp/mupdf-zig-pages
for i in 01 02 03 04 05 06 07 08 09 10; do
  echo "%%MediaBox 0 0 612 792" > /tmp/mupdf-zig-pages/page${i}.txt
done
mutool create -o tests/fixtures/sample-10pages.pdf /tmp/mupdf-zig-pages/page*.txt
mutool info tests/fixtures/sample-10pages.pdf  # expect "Pages: 10"
```

## `not-a-pdf.txt` — plain text used to exercise `InvalidPdf`

```bash
printf 'this is not a pdf\n' > tests/fixtures/not-a-pdf.txt
```

## `encrypted.pdf` — password-protected PDF used to exercise `EncryptedPdf`

```bash
mutool clean -E rc4-128 -U "lockme" \
    tests/fixtures/sample-10pages.pdf \
    tests/fixtures/encrypted.pdf
```

User password: `lockme`. The library doesn't take a password — opening this file should return `error.EncryptedPdf`.

Note: `-U` sets the *user* password (required to view). `-P` is permission flags, not a password. We do NOT set an owner password (`-O`) because that would make `pdf_open_document` itself throw before `pdf_needs_password` can be consulted.
