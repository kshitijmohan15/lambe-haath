"""Entry point: python -m agents.prompt_agent

`--once <prompt_name> <params_json>` runs a single prompt for debugging.
Default mode: stdio JSON-RPC server loop.
"""

import json
import logging
import sys

from agents.prompt_agent.server import run_server, handle_once


def main() -> int:
    if len(sys.argv) >= 2 and sys.argv[1] == "--once":
        logging.basicConfig(
            level=logging.INFO,
            stream=sys.stderr,
            format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        )
        if len(sys.argv) < 4:
            print(
                "usage: python -m agents.prompt_agent --once <prompt_name> <params_json>",
                file=sys.stderr,
            )
            return 2
        prompt_name = sys.argv[2]
        params = json.loads(sys.argv[3])
        result = handle_once(prompt_name, params)
        print(json.dumps(result, indent=2))
        return 0

    logging.basicConfig(
        level=logging.INFO,
        stream=sys.stderr,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    return run_server()


if __name__ == "__main__":
    sys.exit(main())
