"""Entry point: python -m agents.ocr_agent

If `--once <pdf> <out>` is given, run a single OCR job (debug mode, no JSON-RPC).
Otherwise, run the stdio JSON-RPC server loop (production: spawned by logos).
"""

import json
import logging
import sys
from pathlib import Path

from agents.ocr_agent.extract import extract_and_save
from agents.ocr_agent.server import run_server


def main() -> int:
    if len(sys.argv) >= 2 and sys.argv[1] == "--once":
        # Debug mode: single CLI invocation, print result as JSON to stdout.
        # All logs go to stderr so they don't corrupt the JSON output.
        logging.basicConfig(
            level=logging.INFO,
            stream=sys.stderr,
            format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        )
        if len(sys.argv) < 4:
            print(
                "usage: python -m agents.ocr_agent --once <pdf_path> <output_dir>",
                file=sys.stderr,
            )
            return 2
        pdf = Path(sys.argv[2])
        out_dir = Path(sys.argv[3])
        result = extract_and_save(pdf, out_dir)
        # Convert Path objects to strings for JSON serialization.
        printable = {
            k: (str(v) if hasattr(v, "__fspath__") else v)
            for k, v in result.items()
        }
        print(json.dumps(printable, indent=2, default=str))
        return 0

    # Server mode: JSON-RPC over stdio.
    # Critical: send all log output to stderr so stdout stays a clean RPC channel.
    logging.basicConfig(
        level=logging.INFO,
        stream=sys.stderr,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    return run_server()


if __name__ == "__main__":
    sys.exit(main())
