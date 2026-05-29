"""Agent-local Gemini context cache.

Maintains an in-process dict keyed by a hash of the (slices + RUDs) payload.
When a `prompt.run` arrives, we look up an existing Gemini `cachedContents`
resource for that content. Cache misses create a fresh resource and store
its name + expiry. Misses on expired entries trigger re-creation.

This is V0 — no DB persistence, no cross-worker sharing. A daemon restart
or worker recycling re-creates caches. Gemini's TTL handles cleanup.
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
import time
from pathlib import Path
from typing import Optional

log = logging.getLogger("prompt_agent.cache")

# In-memory map: content_hash -> (cache_name, expires_at_epoch_seconds)
_CACHE: dict[str, tuple[str, float]] = {}

# Default TTL is 1 hour. Override with LAMBE_CACHE_TTL_SECONDS (int seconds).
DEFAULT_TTL_SECONDS = 3600


def _hash_content(slices_map: dict, ruds_list: list) -> str:
    """Stable hash of the full slices + RUDs payload.

    Hash inputs:
      - Sorted slice keys + their markdown_path values
      - Sorted RUD ids + their markdown_path values
      - File mtimes (so a re-OCR invalidates the hash)
    """
    parts: list[tuple] = []
    for k in sorted(slices_map.keys()):
        info = slices_map[k]
        md_path = info.get("markdown_path")
        mtime = Path(md_path).stat().st_mtime if md_path and Path(md_path).exists() else 0
        parts.append(("slice", k, md_path, mtime))
    for r in sorted(ruds_list, key=lambda x: x.get("id", "")):
        md_path = r.get("markdown_path")
        mtime = Path(md_path).stat().st_mtime if md_path and Path(md_path).exists() else 0
        parts.append(("rud", r.get("id"), md_path, mtime))
    return hashlib.sha256(json.dumps(parts, sort_keys=True).encode()).hexdigest()


def _ttl_seconds() -> int:
    v = os.environ.get("LAMBE_CACHE_TTL_SECONDS")
    if v is None:
        return DEFAULT_TTL_SECONDS
    try:
        n = int(v)
        if n < 60 or n > 86400:
            log.warning("LAMBE_CACHE_TTL_SECONDS=%s out of [60,86400]; using default 3600", v)
            return DEFAULT_TTL_SECONDS
        return n
    except ValueError:
        log.warning("LAMBE_CACHE_TTL_SECONDS=%s not an int; using default 3600", v)
        return DEFAULT_TTL_SECONDS


def get_or_create_cache(
    model: str,
    slices_map: dict,
    ruds_list: list,
    on_log=None,
) -> Optional[str]:
    """Return the Gemini cachedContents resource name for the given inputs.

    Returns None if caching can't be applied (non-Gemini model, content too
    small for caching, or any SDK error). Callers should fall back to the
    full-text inline flow on None.
    """
    if not model.startswith("gemini-"):
        return None  # only Gemini supports this caching API

    h = _hash_content(slices_map, ruds_list)
    now = time.time()

    entry = _CACHE.get(h)
    if entry and entry[1] > now + 30:  # 30s safety margin
        if on_log:
            on_log("info", f"cache hit ({entry[0]})")
        return entry[0]

    # Cache miss — assemble content from disk and create the resource.
    assembled = _assemble_content(slices_map, ruds_list)
    if len(assembled) < 4096:  # rough guard for Gemini's min cacheable size
        if on_log:
            on_log("info", "content below cache threshold; skipping")
        return None

    try:
        from google import genai
        from google.genai import types
    except ImportError:
        if on_log:
            on_log("warning", "google-genai not installed; cannot cache")
        return None

    try:
        client = genai.Client(api_key=os.environ.get("GEMINI_API_KEY") or os.environ.get("GOOGLE_API_KEY"))
        ttl = _ttl_seconds()
        cache = client.caches.create(
            model=model,
            config=types.CreateCachedContentConfig(
                contents=[types.Content(role="user", parts=[types.Part(text=assembled)])],
                ttl=f"{ttl}s",
            ),
        )
        cache_name = cache.name
        _CACHE[h] = (cache_name, now + ttl)
        if on_log:
            on_log("info", f"cache created ({cache_name}, ttl={ttl}s)")
        return cache_name
    except Exception as e:
        # Cache creation can fail for many reasons (content too small, API quota,
        # invalid model, etc.). Log and fall through — caller uses inline flow.
        log.warning("cache.create failed: %s", e, exc_info=True)
        if on_log:
            on_log("warning", f"cache create failed: {e}; falling back to inline")
        return None


def _assemble_content(slices_map: dict, ruds_list: list) -> str:
    """Concatenate ALL slice markdowns + ALL RUDs into one text blob.

    This is the cached payload — not filtered by spec.requires (the cache is
    shared across all prompts of a chargesheet; the per-prompt system prompt
    handles selection).
    """
    parts: list[str] = []
    for k in sorted(slices_map.keys()):
        info = slices_map[k]
        md_path = info.get("markdown_path")
        if md_path and Path(md_path).exists():
            parts.append(f"\n\n# {k.upper()}\n\n{Path(md_path).read_text(encoding='utf-8')}")
    for r in sorted(ruds_list, key=lambda x: x.get("id", "")):
        md_path = r.get("markdown_path")
        if md_path and Path(md_path).exists():
            parts.append(f"\n\n## {r.get('id', 'RUD-??')}\n\n{Path(md_path).read_text(encoding='utf-8')}")
    return "\n".join(parts).lstrip()
