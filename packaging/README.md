# logos — chargesheet slicing tool (@VERSION@)

A self-contained PDF chargesheet slicing tool: one CLI that runs a local daemon
and serves the web UI on http://localhost:7777.

## Run

    ./logos -p 7777        # macOS / Linux
    .\logos.exe -p 7777    # Windows

Then open http://localhost:7777 in your browser. Press Ctrl+C to stop.

The web UI is the `ui/` folder next to this binary; keep them together.

## Unsigned binary note

These binaries are not code-signed.

- macOS: the first run may be blocked ("cannot be opened because the developer
  cannot be verified"). Allow it once with:
      xattr -d com.apple.quarantine ./logos
  or System Settings → Privacy & Security → "Open Anyway".
- Windows: SmartScreen may warn ("Windows protected your PC"). Click
  "More info" → "Run anyway".
