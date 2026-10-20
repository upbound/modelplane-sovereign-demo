#!/usr/bin/env python3
"""Record a demo beat to an asciicast v2 file, and replay it on stage.

  cast.py rec FILE -- CMD [ARGS...]   run CMD in a pseudo-terminal, show its
                                      output, and record it with its timings
  cast.py play FILE                   replay FILE, stopping at each pause until
                                      ENTER, as the live script does

demo.sh marks each pause in its output with an OSC sequence, ESC ] 1337 ;
DemoPause=<prompt> BEL. rec turns each into an asciicast marker event, so the
files also play in asciinema.

play keeps the recorded timing, so streamed tokens arrive as they did, with two
exceptions. A gap longer than CAST_MAX_GAP seconds (default 1.5) is shortened
to it. A wait's spinner frames play every CAST_WAIT_STEP seconds (default 0.1),
so a two-minute wait takes a few seconds; the elapsed time it ends with is the
recorded one. CAST_SPEED divides every gap, and CAST_AUTO=SECS sleeps at
pauses instead of waiting for ENTER.
"""
import codecs
import fcntl
import json
import os
import pty
import re
import struct
import sys
import termios
import time

PREFIX = b"\x1b]1337;DemoPause="
MARK = re.compile(re.escape(PREFIX) + rb"([^\x07]*)\x07")
# Every frame of demo.sh's wait_for spinner, and the line it ends on, starts
# by returning to the start of the line and clearing it.
SPINNER = "\r\x1b[K"


def rec(path, argv):
    try:
        cols, rows = os.get_terminal_size()
    except OSError:
        cols, rows = 100, 32
    pid, fd = pty.fork()
    if pid == 0:
        fcntl.ioctl(1, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        os.execvp(argv[0], argv)

    start = time.monotonic()
    decode = codecs.getincrementaldecoder("utf-8")("replace").decode
    pending = b""
    with open(path, "w") as out:
        header = {"version": 2, "width": cols, "height": rows, "timestamp": int(time.time()),
                  "env": {"TERM": os.environ.get("TERM", "xterm-256color")}}
        out.write(json.dumps(header) + "\n")

        def emit(kind, data):
            if data:
                out.write(json.dumps([round(time.monotonic() - start, 6), kind, data]) + "\n")

        def show(raw):
            text = decode(raw)
            emit("o", text)
            sys.stdout.write(text)

        while True:
            try:
                chunk = os.read(fd, 65536)
            except OSError:  # EIO: the command closed the terminal
                break
            if not chunk:
                break
            pending += chunk
            # Hold back what may be the start of a marker split across reads.
            cut = len(pending)
            i = pending.rfind(b"\x1b]")
            tail = pending[i:] if i != -1 else b""
            if tail and b"\x07" not in tail and (tail.startswith(PREFIX) or PREFIX.startswith(tail)):
                cut = i
            buf, pending = pending[:cut], pending[cut:]
            pos = 0
            for m in MARK.finditer(buf):
                show(buf[pos:m.start()])
                emit("m", m.group(1).decode("utf-8", "replace"))
                pos = m.end()
            show(buf[pos:])
            sys.stdout.flush()
        show(pending)
    _, status = os.waitpid(pid, 0)
    return os.waitstatus_to_exitcode(status)


def pause(label, auto):
    sys.stdout.write(f"\x1b[2m↪ {label}…\x1b[0m")
    sys.stdout.flush()
    if auto is not None:
        time.sleep(auto)
        sys.stdout.write("\n")
        return
    # Drop keys pressed while the output played, so they can't skip this pause.
    if sys.stdin.isatty():
        termios.tcflush(sys.stdin, termios.TCIFLUSH)
    sys.stdin.readline()


def play(path):
    speed = float(os.environ.get("CAST_SPEED", 1))
    max_gap = float(os.environ.get("CAST_MAX_GAP", 1.5))
    wait_step = float(os.environ.get("CAST_WAIT_STEP", 0.1))
    auto = os.environ.get("CAST_AUTO")
    auto = float(auto) if auto else None
    with open(path) as f:
        json.loads(f.readline())
        events = [json.loads(line) for line in f if line.strip()]
    prev = 0.0
    for t, kind, data in events:
        gap, prev = (t - prev) / speed, t
        if kind == "o":
            time.sleep(min(gap, wait_step if data.startswith(SPINNER) else max_gap))
            sys.stdout.write(data)
            sys.stdout.flush()
        elif kind == "m":
            time.sleep(min(gap, max_gap))
            pause(data, auto)
    return 0


def main():
    args = sys.argv[1:]
    if len(args) >= 4 and args[0] == "rec" and args[2] == "--":
        return rec(args[1], args[3:])
    if len(args) == 2 and args[0] == "play":
        try:
            return play(args[1])
        except KeyboardInterrupt:
            sys.stdout.write("\x1b[0m\n")
            return 130
    sys.stderr.write(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
