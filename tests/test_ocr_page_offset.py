"""Boundary semantics for OCR page offsetting.

The OCR agent's extract_and_save accepts a `start_page` argument representing
the absolute page number of the slice's first page in the ORIGINAL document.
Inside, it uses `absolute_page_range` to map slice-internal 1-based inclusive
chunks to absolute 1-based inclusive ranges. These tests lock the boundary
contract: 1-based, inclusive on both ends, end-to-end.
"""

import pytest

from agents.ocr_agent.extract import absolute_page_range


class TestStartPageOne:
    """When start_page=1 (slice IS the document), offsets are zero — ranges pass through."""

    def test_passthrough_full_range(self):
        assert absolute_page_range(1, 1, 10) == (1, 10)

    def test_passthrough_single_page(self):
        assert absolute_page_range(1, 5, 5) == (5, 5)

    def test_passthrough_first_page(self):
        assert absolute_page_range(1, 1, 1) == (1, 1)


class TestMidDocumentSlice:
    """AnnexureII spans pages 70..170 (101 pages) of the original document."""

    def test_full_slice_to_absolute(self):
        # _chunk_pdf yields (1, 101) for the whole slice if it fits in one chunk
        assert absolute_page_range(70, 1, 101) == (70, 170)

    def test_first_chunk(self):
        # 40-page first chunk inside a multi-chunk slice
        assert absolute_page_range(70, 1, 40) == (70, 109)

    def test_middle_chunk(self):
        assert absolute_page_range(70, 41, 80) == (110, 149)

    def test_last_chunk(self):
        # Slice has 101 pages; chunks (1,40)(41,80)(81,101) → abs (70,109)(110,149)(150,170)
        assert absolute_page_range(70, 81, 101) == (150, 170)

    def test_single_page_slice_at_offset(self):
        assert absolute_page_range(70, 1, 1) == (70, 70)


class TestBoundaryInvariants:
    """Properties that must hold for any (start_page, slice_start, slice_end) input."""

    @pytest.mark.parametrize("start_page", [1, 2, 70, 1000])
    @pytest.mark.parametrize(
        "slice_start,slice_end",
        [(1, 1), (1, 40), (41, 80), (1, 101), (81, 101), (50, 50)],
    )
    def test_length_preserved(self, start_page, slice_start, slice_end):
        """The output range has the same length as the input range."""
        abs_start, abs_end = absolute_page_range(start_page, slice_start, slice_end)
        assert abs_end - abs_start == slice_end - slice_start

    @pytest.mark.parametrize("start_page", [1, 2, 70, 1000])
    @pytest.mark.parametrize("slice_start", [1, 40, 81])
    def test_first_slice_page_maps_to_start_page(self, start_page, slice_start):
        """slice-internal page 1 always maps to absolute page start_page."""
        abs_one, _ = absolute_page_range(start_page, 1, 1)
        assert abs_one == start_page

    def test_chunks_cover_slice_without_gaps_or_overlap(self):
        """A slice split into contiguous chunks produces contiguous, non-overlapping
        absolute ranges. Verifies the math is consistent across consecutive chunks."""
        # Slice of 101 pages, chunked into (1,40)(41,80)(81,101) at offset 70:
        ranges = [
            absolute_page_range(70, 1, 40),
            absolute_page_range(70, 41, 80),
            absolute_page_range(70, 81, 101),
        ]
        # Each chunk's start = previous chunk's end + 1
        for prev, cur in zip(ranges, ranges[1:]):
            assert cur[0] == prev[1] + 1, f"gap or overlap between {prev} and {cur}"
        # First page of first chunk = 70 (start_page); last page of last chunk = 170
        assert ranges[0][0] == 70
        assert ranges[-1][1] == 170
        # Total pages covered = 101 (the slice length)
        total = sum(end - start + 1 for start, end in ranges)
        assert total == 101
