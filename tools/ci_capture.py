#!/usr/bin/env python3
"""Stream CI output; expose a bounded failure tail in GitHub annotations.

The sandbox can read GitHub's API, but not the external Actions log blob host.
No extra token/checks-write permission is needed. This is CI tooling only,
not the application logger or a mechanism for executing project-defined hooks.
"""
import os
import subprocess
import sys

TAIL_BYTES = 16 * 1024


def main(arguments):
    if not arguments:
        print("usage: ci_capture.py <executable> [arguments...]", file=sys.stderr)
        return 2
    try:
        child = subprocess.Popen(arguments, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    except OSError as error:
        print(f"could not launch CI command: {error}", file=sys.stderr)
        return 127
    tail = bytearray()
    try:
        with child.stdout:
            while block := child.stdout.read1(4096):
                sys.stdout.buffer.write(block)
                sys.stdout.buffer.flush()
                tail.extend(block)
                if len(tail) > TAIL_BYTES:
                    del tail[:-TAIL_BYTES]
        status = child.wait()
    finally:
        if child.poll() is None:
            child.kill()
            child.wait()
    if status and os.environ.get("GITHUB_ACTIONS") == "true":
        # Workflow commands are recognized only at the start of a line. The
        # streamed child output may end without a newline (or even with CR).
        if tail and tail[-1] != 10:
            sys.stdout.write("\n")
        message = tail.decode("utf-8", errors="replace")
        message = message.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
        print(f"::error title=CI command failed::exit {status}: {message}", flush=True)
    return status if status >= 0 else 128 - status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
