import hashlib
import json
import logging
import os
import re
import tempfile
import time
from datetime import datetime, timezone
from io import BytesIO
from pathlib import Path
from typing import Iterator, Callable, Optional

from google import genai
from pypdf import PdfReader, PdfWriter

logger = logging.getLogger(__name__)

DEFAULT_MODEL = "gemini-2.5-flash"
# Gemini's generateContent rejects PDFs above ~50 MB even via Files API.
# Empirically: 41 MB passes, 59 MB fails. 49 MB leaves headroom.
BATCH_BYTES_MAX = 49 * 1024 * 1024
# Cap pages per chunk to stay under gemini-2.5-flash's 65,536 output-token budget.
# Empirically ~1,250 output tokens/page for OCR'd Indian legal PDFs; 40 pages ≈ 50k.
BATCH_PAGES_MAX = 40
# Streaming heartbeat interval (seconds) — logs progress while tokens stream in.
STREAM_HEARTBEAT_S = 10.0

PAGE_MARKER_RE = re.compile(r"^<!-- page: (\d+) -->$", re.MULTILINE)
OUTER_FENCE_RE = re.compile(r"^```(?:markdown)?\s*\n(.*)\n```\s*$", re.DOTALL)

# Lazy-loaded genai client
_genai_client: Optional[genai.Client] = None


def get_model() -> str:
    """Get the model name, respecting LAMBE_MODEL env var override."""
    return os.environ.get("LAMBE_MODEL", DEFAULT_MODEL)


def _get_client() -> genai.Client:
    """Lazy-load and cache the genai client."""
    global _genai_client
    if _genai_client is None:
        _genai_client = genai.Client()
    return _genai_client


def _prompt_for_chunk(start_page: int, end_page: int) -> str:
    return (
        "Transcribe this entire PDF verbatim into clean Markdown. Preserve "
        "columns, tables, lists, and headers.\n\n"
        f"This PDF contains pages {start_page} through {end_page} of a larger "
        "document. At every PDF page boundary, insert exactly this HTML "
        "comment on its own line immediately before that page's content:\n\n"
        "<!-- page: N -->\n\n"
        f"N is the absolute page number: start at {start_page} for the first "
        f"page of this PDF and increment by 1 for each subsequent page "
        f"(so the sequence is {start_page}, {start_page + 1}, ..., {end_page}).\n"
        f"The very first line of your output MUST be: <!-- page: {start_page} -->\n"
        "Do NOT wrap your output in code fences. Do NOT add commentary."
    )


def _serialize_size(reader: PdfReader, start: int, end_excl: int) -> int:
    w = PdfWriter()
    for k in range(start, end_excl):
        w.add_page(reader.pages[k])
    buf = BytesIO()
    w.write(buf)
    return buf.tell()


def _write_chunk(reader: PdfReader, start: int, end_excl: int, out_path: Path) -> int:
    w = PdfWriter()
    for k in range(start, end_excl):
        w.add_page(reader.pages[k])
    with open(out_path, "wb") as fh:
        w.write(fh)
    return out_path.stat().st_size


def _max_pages_fitting(
    reader: PdfReader, start: int, max_bytes: int, max_pages: int
) -> int:
    """Largest k <= max_pages such that pages[start:start+k] serialize to
    <= max_bytes. 0 means even one page overflows max_bytes."""
    remaining = min(len(reader.pages) - start, max_pages)
    if remaining <= 0:
        return 0

    probe = 1
    last_ok = 0
    overflow_at = 0
    while probe <= remaining:
        size = _serialize_size(reader, start, start + probe)
        if size <= max_bytes:
            last_ok = probe
            if probe == remaining:
                return last_ok
            probe = min(probe * 2, remaining)
        else:
            overflow_at = probe
            break
    else:
        return last_ok

    lo, hi = last_ok, overflow_at - 1
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if _serialize_size(reader, start, start + mid) <= max_bytes:
            lo = mid
        else:
            hi = mid - 1
    return lo


def _chunk_pdf(
    pdf_path: Path, max_bytes: int, tmp_dir: Path
) -> Iterator[tuple[int, int, Path, int]]:
    """Yield (start_page_1based, end_page_1based_inclusive, chunk_path, size_bytes)."""
    reader = PdfReader(str(pdf_path))
    n = len(reader.pages)
    i = 0
    idx = 0
    while i < n:
        k = _max_pages_fitting(reader, i, max_bytes, BATCH_PAGES_MAX)
        if k == 0:
            logger.warning(
                "Page %d alone exceeds %d bytes; sending it solo (will likely 400)",
                i + 1, max_bytes,
            )
            k = 1
        chunk_path = tmp_dir / f"chunk_{idx:03d}.pdf"
        size = _write_chunk(reader, i, i + k, chunk_path)
        yield (i + 1, i + k, chunk_path, size)
        i += k
        idx += 1


def _strip_outer_fence(text: str) -> str:
    text = text.strip()
    m = OUTER_FENCE_RE.match(text)
    return m.group(1).strip() if m else text


def _extract_chunk(
    client: genai.Client,
    chunk_path: Path,
    start_page: int,
    end_page: int,
    model: str,
    on_log: Optional[Callable[[str, str], None]] = None,
) -> tuple[str, float, int | None, int | None]:
    msg = f"Uploading chunk {chunk_path.name} (pages {start_page}-{end_page})"
    logger.info(msg)
    if on_log:
        on_log("info", msg)

    uploaded = client.files.upload(file=str(chunk_path))
    if uploaded.name is None:
        raise RuntimeError(f"Upload of {chunk_path} returned no name")

    msg = f"Uploaded as {uploaded.name} (state={uploaded.state})"
    logger.info(msg)
    if on_log:
        on_log("info", msg)

    started = time.time()
    parts: list[str] = []
    input_tokens: int | None = None
    output_tokens: int | None = None
    finish_reason = None
    try:
        stream = client.models.generate_content_stream(
            model=model,
            contents=[uploaded, _prompt_for_chunk(start_page, end_page)],
        )
        last_log = started
        for resp in stream:
            if resp.text:
                parts.append(resp.text)
            if resp.usage_metadata is not None:
                input_tokens = resp.usage_metadata.prompt_token_count
                output_tokens = resp.usage_metadata.candidates_token_count
            if resp.candidates:
                fr = resp.candidates[0].finish_reason
                if fr is not None:
                    finish_reason = fr
            now = time.time()
            if now - last_log >= STREAM_HEARTBEAT_S:
                msg = (
                    f"  ...streaming pages {start_page}-{end_page}: "
                    f"{sum(len(p) for p in parts)} chars, {now - started:.0f}s elapsed"
                )
                logger.info(msg)
                if on_log:
                    on_log("info", msg)
                last_log = now
        latency = time.time() - started
        text = "".join(parts)
        if not text:
            raise RuntimeError(f"Empty extraction for chunk pages {start_page}-{end_page}")
        msg = (
            f"Chunk pages {start_page}-{end_page} done in {latency:.2f}s "
            f"(tokens: in={input_tokens} out={output_tokens}, chars={len(text)}, finish={finish_reason})"
        )
        logger.info(msg)
        if on_log:
            on_log("info", msg)

        if finish_reason is not None and str(finish_reason).split(".")[-1] not in ("STOP", "FinishReason.STOP"):
            msg = (
                f"Chunk pages {start_page}-{end_page} finished with non-STOP reason: "
                f"{finish_reason} (output may be truncated)"
            )
            logger.warning(msg)
            if on_log:
                on_log("warning", msg)
    finally:
        msg = f"Deleting uploaded file {uploaded.name}"
        logger.info(msg)
        if on_log:
            on_log("info", msg)
        client.files.delete(name=uploaded.name)

    return _strip_outer_fence(text), latency, input_tokens, output_tokens


def absolute_page_range(start_page: int, slice_start: int, slice_end: int) -> tuple[int, int]:
    """Convert a slice-internal 1-based, inclusive page range to absolute page
    numbers in the original document.

    `start_page` is the absolute page number of the slice's first page within
    the original document (so slice-internal page 1 ↔ absolute page start_page).
    `(slice_start, slice_end)` is a 1-based inclusive range within the slice.

    Returns the equivalent 1-based inclusive range in the original document.

    Examples (all 1-based inclusive):
        absolute_page_range(1,  1, 10) == (1, 10)    # slice IS the document
        absolute_page_range(70, 1, 101) == (70, 170) # AnnexureII spanning 101 pages
        absolute_page_range(70, 1, 1)   == (70, 70)  # single-page slice
        absolute_page_range(70, 41, 80) == (110, 149) # mid-document chunk
    """
    offset = start_page - 1
    return slice_start + offset, slice_end + offset


def _build_page_index(md: str) -> list[dict]:
    matches = list(PAGE_MARKER_RE.finditer(md))
    pages: list[dict] = []
    for k, m in enumerate(matches):
        content_start = m.end() + 1  # past the newline after the marker line
        content_end = matches[k + 1].start() if k + 1 < len(matches) else len(md)
        pages.append({
            "page": int(m.group(1)),
            "char_start": content_start,
            "char_end": content_end,
        })
    return pages


def extract_and_save(
    pdf_path: Path,
    output_dir: Path,
    on_progress: Optional[Callable[[float, str], None]] = None,
    on_log: Optional[Callable[[str, str], None]] = None,
    start_page: int = 1,
) -> dict:
    """Extract a PDF to markdown + meta.json under output_dir.

    Args:
        pdf_path: Path to the PDF file.
        output_dir: Directory where markdown and meta.json will be written.
        on_progress: Optional callback(progress: float 0-1, message: str) for chunk completion.
        on_log: Optional callback(level: str, message: str) for log messages.
        start_page: Absolute page number of pdf_path's first page within the
            original (pre-sliced) document. Page markers in the output markdown
            will be numbered start_page .. start_page + total_pages - 1. Defaults
            to 1 (standalone PDF, no offset).

    Returns:
        {"markdown_path": Path, "meta_path": Path, "metadata": dict}.
    """
    output_dir.mkdir(parents=True, exist_ok=True)

    pdf_bytes = pdf_path.read_bytes()
    content_hash = hashlib.sha256(pdf_bytes).hexdigest()[:16]
    reader = PdfReader(str(pdf_path))
    total_pages = len(reader.pages)
    msg = (
        f"Processing {pdf_path.name} ({len(pdf_bytes)} bytes, {total_pages} pages, sha256={content_hash})"
    )
    logger.info(msg)
    if on_log:
        on_log("info", msg)

    md_path = output_dir / f"{pdf_path.stem}.md"
    meta_path = output_dir / f"{pdf_path.stem}.meta.json"

    client = _get_client()
    model = get_model()
    parts: list[str] = []
    chunks_meta: list[dict] = []
    total_latency = 0.0
    total_in = 0
    total_out = 0

    with tempfile.TemporaryDirectory() as tmp:
        tmp_dir = Path(tmp)
        chunks = list(_chunk_pdf(pdf_path, BATCH_BYTES_MAX, tmp_dir))
        msg = f"Split into {len(chunks)} chunk(s) under {BATCH_BYTES_MAX // 1024 // 1024} MB each"
        logger.info(msg)
        if on_log:
            on_log("info", msg)

        # `start_page` parameter is the absolute starting page in the original
        # document. _chunk_pdf yields 1-based positions within the SLICE; map
        # them to absolute via absolute_page_range so emitted markers and
        # chunk metadata reflect the original (e.g., AnnexureII.pdf with
        # start_page=70 produces markers 70..170 instead of 1..101).
        for idx, (slice_start, slice_end, chunk_path, chunk_size) in enumerate(chunks):
            abs_start, abs_end = absolute_page_range(start_page, slice_start, slice_end)
            msg = f"Chunk pages {abs_start}-{abs_end}: {chunk_size / 1024 / 1024:.1f} MB"
            logger.info(msg)
            if on_log:
                on_log("info", msg)

            md, latency, in_tok, out_tok = _extract_chunk(
                client, chunk_path, abs_start, abs_end, model, on_log=on_log
            )
            parts.append(md)
            chunks_meta.append({
                "start_page": abs_start,
                "end_page": abs_end,
                "size_bytes": chunk_size,
                "latency_s": round(latency, 2),
                "input_tokens": in_tok,
                "output_tokens": out_tok,
                "output_chars": len(md),
            })
            total_latency += latency
            total_in += in_tok or 0
            total_out += out_tok or 0

            # Emit progress callback
            if on_progress:
                progress = (idx + 1) / len(chunks)
                on_progress(progress, f"chunk {idx + 1}/{len(chunks)} done")

    combined = "\n\n".join(parts).strip() + "\n"
    md_path.write_text(combined, encoding="utf-8")
    msg = f"Wrote transcript to {md_path} ({len(combined)} chars)"
    logger.info(msg)
    if on_log:
        on_log("info", msg)

    page_index = _build_page_index(combined)
    if len(page_index) != total_pages:
        msg = (
            f"Expected {total_pages} page markers, found {len(page_index)} — "
            "model emission imperfect"
        )
        logger.warning(msg)
        if on_log:
            on_log("warning", msg)

    metadata = {
        "source_pdf": str(pdf_path),
        "source_sha256_prefix": content_hash,
        "source_bytes": len(pdf_bytes),
        "source_pages": total_pages,
        "model": model,
        "batch_bytes_max": BATCH_BYTES_MAX,
        "extracted_at": datetime.now(timezone.utc).isoformat(),
        "total_latency_s": round(total_latency, 2),
        "total_input_tokens": total_in or None,
        "total_output_tokens": total_out or None,
        "output_chars": len(combined),
        "markdown_path": str(md_path),
        "page_markers_found": len(page_index),
        "page_markers_expected": total_pages,
        "pages": page_index,
        "chunks": chunks_meta,
    }
    meta_path.write_text(json.dumps(metadata, indent=2))
    msg = f"Wrote metadata to {meta_path}"
    logger.info(msg)
    if on_log:
        on_log("info", msg)

    return {"markdown_path": md_path, "meta_path": meta_path, "metadata": metadata}
