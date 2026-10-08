#!/usr/bin/env python3
"""Exercise the real DOOM loop, stdin parser and renderer through a PTY.

The link wrapper only records events returned to I_GetEvent; no fake clock or
replacement loop. Output starvation models a slow surface reader independently
of keyboard repeat. Scratch files stay under the ignored engine build directory.
"""
import fcntl
import os
from pathlib import Path
import pty
import re
import signal
import select
import struct
import subprocess
import tempfile
import time
import termios

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "engine/src/build-thurbox"


def ticks():
    return int(time.monotonic() * 1000) & 0xffffffff


def run():
    subprocess.run(["make", "-C", str(ROOT / "engine/src"), "-s", "doom"], check=True)
    objects = sorted(str(p) for p in BUILD.glob("*.o"))
    with tempfile.TemporaryDirectory(prefix="input-", dir=BUILD) as scratch:
        binary = Path(scratch) / "doom-traced"
        trace = Path(scratch) / "events"
        menu_trace = Path(scratch) / "menu"
        tick_trace = Path(scratch) / "ticks"
        subprocess.run(["cc", "-O2", "-I" + str(ROOT / "engine/src"),
                        str(ROOT / "tests/input_trace.c"), *objects,
                        "-Wl,--wrap=DG_GetKey", "-Wl,--wrap=M_Responder", "-Wl,--wrap=G_Ticker", "-lm", "-o", str(binary)], check=True)
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 100, 0, 0))
        env = dict(os.environ, DOOM_INPUT_TRACE=str(trace),
                   DOOM_MENU_TRACE=str(menu_trace), DOOM_TICK_TRACE=str(tick_trace))
        proc = subprocess.Popen([str(binary), "-iwad", str(ROOT / "wad/doom1.wad"),
                                 "-warp", "1", "1", "-config", str(Path(scratch) / "config")],
                                stdin=slave, stdout=slave, stderr=slave, cwd=scratch, env=env)
        os.close(slave)
        failures = []
        output = bytearray()

        def events():
            if not trace.exists():
                return []
            return [tuple(map(int, line.split())) for line in trace.read_text().splitlines()]

        def wait(seconds, drain=True):
            end = time.monotonic() + seconds
            while time.monotonic() < end:
                if drain and select.select([master], [], [], 0.002)[0]:
                    output.extend(os.read(master, 65536))
                else:
                    time.sleep(0.002)
                if proc.poll() is not None:
                    raise AssertionError("engine exited during test")

        def check(ok, label):
            print(("PASS " if ok else "FAIL ") + label, flush=True)
            if not ok:
                failures.append(label)

        try:
            wait(1.5)
            start = ticks()
            os.write(master, b"w")
            wait(0.12)
            down = [e for e in events() if e[1:] == (1, 0xad)]
            latency = down[-1][0] - start if down else None
            check(latency is not None and latency < 100,
                  f"draining output: first movement reaches engine in {latency} ms")
            wait(0.48)
            for _ in range(5):
                os.write(master, b"w")
                wait(0.04)
            wait(0.18)
            start = ticks()
            os.write(master, b"w")
            wait(0.6)
            premature = [e for e in events() if start <= e[0] < start + 580 and e[1:] == (0, 0xad)]
            check(not premature, "second hold survives 600 ms initial repeat delay")
            os.write(master, b"w")
            for _ in range(5):
                wait(0.04)
                os.write(master, b"w")
            last = ticks()
            wait(0.18)
            ups = [e for e in events() if e[0] >= last and e[1:] == (0, 0xad)]
            stop = ups[0][0] - last if ups else None
            check(stop is not None and stop < 160, f"repeat release after {stop} ms")

            # A changing view fills the output PTY. Stop reading, then send a new
            # key: input must still reach I_GetEvent while the frame cannot flush.
            os.write(master, b"e")
            wait(0.25, drain=False)
            start = ticks()
            os.write(master, b"f")
            wait(0.35, drain=False)
            stalled_ticks = [int(line) for line in tick_trace.read_text().splitlines()
                             if int(line) >= start]
            check(len(stalled_ticks) >= 5,
                  f"simulation continues during 350 ms output stall: {len(stalled_ticks)} ticks")
            fire = [e for e in events() if e[0] >= start and e[1:] == (1, 0xa3)]
            latency = fire[0][0] - start if fire else None
            check(latency is not None and latency < 100,
                  f"blocked output: fire reaches engine in {latency} ms (observed for 350 ms)")
            # Resize with a partially written frame still outstanding. The
            # old frame must finish before its storage and geometry are reused.
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
            proc.send_signal(signal.SIGWINCH)
            resume_offset = len(output)
            wait(0.3)
            check(b"\x1b[2J" in output[resume_offset:], "output resumes and redraws after resize")
            markers = re.findall(rb"\x1b\[\?2026([hl])", output)
            check(bool(markers) and all(m == (b"h" if i % 2 == 0 else b"l")
                                       for i, m in enumerate(markers)),
                  "partial frame writes preserve synchronized-output ordering")
            fire = [e for e in events() if e[0] >= start and e[1:] == (1, 0xa3)]
            print("output resumed: fire latency", fire[0][0] - start if fire else None, "ms", flush=True)
            start = ticks()
            os.write(master, b"s" * 1024 + b"\t")
            wait(0.3)
            tabs = [e for e in events() if e[0] >= start and e[1:] == (1, 9)]
            latency = tabs[0][0] - start if tabs else None
            check(latency is not None and latency < 250,
                  f"1024-byte repeat backlog: trailing Tab reaches engine in {latency} ms")
            # Standalone comparison: two real menu actions with a quiet 150 ms
            # gap, no host or SSH transport. An inferred 700 ms hold must not
            # discard the second terminal press.
            os.write(master, b"\x1b")
            wait(0.15)
            start = ticks()
            os.write(master, b"\x1b")
            wait(0.15)
            menu = ([tuple(map(int, line.split())) for line in menu_trace.read_text().splitlines()]
                    if menu_trace.exists() else [])
            latency = menu[1][0] - start if len(menu) > 1 else None
            check(len(menu) == 2 and [e[1] for e in menu] == [1, 0]
                  and latency is not None and latency < 100,
                  f"standalone quick Esc taps open then close menu; second action {latency} ms")
            start = ticks()
            for _ in range(5):
                os.write(master, b"r")
                wait(0.04)
            wait(0.18)
            shift = [e[1] for e in events() if e[0] >= start and e[2] == 0xb6]
            check(shift == [1, 0], "repeated run modifier has one down and one up")
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
            os.close(master)
        assert not failures, "; ".join(failures)


if __name__ == "__main__":
    run()
