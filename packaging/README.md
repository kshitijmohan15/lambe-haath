# logos — chargesheet slicing tool (@VERSION@)

A self-contained PDF chargesheet slicing tool: one CLI that runs a local daemon
and serves the web UI on http://localhost:7777.

## Run

    ./logos -p 7777        # macOS / Linux
    .\logos.exe -p 7777    # Windows

Then open http://localhost:7777 in your browser. Press Ctrl+C to stop.

The web UI is the `ui/` folder next to this binary; keep them together.

## OCR + prompt jobs (optional)

Slicing works out of the box. OCR and prompt jobs need a separate
Python setup:

1. Clone the repo: `git clone https://github.com/kshitijmohan15/lambe-haath`
2. `cd lambe-haath && uv sync --frozen` (requires [uv](https://docs.astral.sh/uv/))
3. Point logos at the clone:  `export LAMBE_AGENTS_DIR=/path/to/lambe-haath`
4. Provide an API key:  `export GEMINI_API_KEY=...`  (Anthropic optional)

Defaults are baked into the binary. To override per-agent settings
(model choice, worker counts, alternate Python interpreter), copy
`agents.json.example` (shipped next to this README) into your data
directory as `agents.json`:

- macOS: `~/Library/Application Support/ChargesheetTool/agents.json`
- Linux: `~/.local/share/chargesheet-tool/agents.json`
- Windows: `%LOCALAPPDATA%\ChargesheetTool\agents.json`

## Unsigned binary note

These binaries are not code-signed.

- macOS: the first run may be blocked ("cannot be opened because the developer
  cannot be verified"). Allow it once with:
      xattr -d com.apple.quarantine ./logos
  or System Settings → Privacy & Security → "Open Anyway".
- Windows: SmartScreen may warn ("Windows protected your PC"). Click
  "More info" → "Run anyway".
