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
        frame_trace = Path(scratch) / "frames"
        subprocess.run(["cc", "-O2", "-I" + str(ROOT / "engine/src"),
                        str(ROOT / "tests/input_trace.c"), *objects,
                        "-Wl,--wrap=DG_GetKey", "-Wl,--wrap=M_Responder", "-Wl,--wrap=G_Ticker", "-Wl,--wrap=DG_DrawFrame", "-lm", "-o", str(binary)], check=True)
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 100, 0, 0))
        env = dict(os.environ, DOOM_INPUT_TRACE=str(trace),
                   DOOM_MENU_TRACE=str(menu_trace), DOOM_TICK_TRACE=str(tick_trace),
                   DOOM_FRAME_TRACE=str(frame_trace))
        proc = subprocess.Popen([str(binary), "-iwad", str(ROOT / "wad/doom1.wad"),
                                 "-warp", "1", "1", "-nomonsters", "-config", str(Path(scratch) / "config")],
                                stdin=slave, stdout=slave, stderr=slave, cwd=scratch, env=env)
        os.close(slave)
        failures = []
        output = bytearray()
        frame_times = []
        frame_end = 0

        def events():
            if not trace.exists():
                return []
            return [tuple(map(int, line.split())) for line in trace.read_text().splitlines()]

        def samples():
            return [tuple(map(int, line.split())) for line in tick_trace.read_text().splitlines()]

        def wait(seconds, drain=True):
            nonlocal frame_end
            end = time.monotonic() + seconds
            while time.monotonic() < end:
                if drain and select.select([master], [], [], 0.002)[0]:
                    output.extend(os.read(master, 65536))
                    while True:
                        finish = output.find(b"\x1b[?2026l", frame_end)
                        if finish < 0:
                            break
                        finish += 8
                        if finish - frame_end > 16:
                            frame_times.append(ticks())
                        frame_end = finish
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
            stalled_ticks = [row for row in samples() if row[0] >= start]
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
            os.write(master, b"\t")  # close the automap opened by the backlog check
            wait(0.15)
            # Physical tap/release is intentionally represented by a single
            # legacy arrow sequence: that terminal has no release event.
            before = samples()[-1][1]
            start = ticks()
            os.write(master, b"\x1b[C")
            wait(0.85)
            after = samples()[-1][1]
            angle = ((before - after) & 0xffffffff) * 360 / 2**32
            up = [e[0] - start for e in events() if e[0] >= start and e[1:] == (0, 0xae)]
            print(f"legacy-only arrow tap turns {angle:.2f} degrees; synthetic release {up} ms", flush=True)

            start = ticks()
            os.write(master, b"\x1b[C")
            wait(0.6)
            for _ in range(15):
                os.write(master, b"\x1b[C")
                wait(0.04)
            last = ticks()
            before_release = samples()[-1][1]
            wait(0.2)
            turned = [row for row, prev in zip(samples()[1:], samples()[:-1])
                      if start <= row[0] <= last and row[1] != prev[1]]
            gaps = [b[0] - a[0] for a, b in zip(turned, turned[1:])]
            repeat_gaps = [b[0] - a[0] for a, b in zip(turned, turned[1:])
                           if a[0] >= start + 650]
            tail_angle = ((before_release - samples()[-1][1]) & 0xffffffff) * 360 / 2**32
            frames = [t for t in frame_times if start + 650 <= t <= last]
            intervals = [b - a for a, b in zip(frames, frames[1:])]
            print(f"held turning: maximum tick gap {max(gaps, default=0)} ms; "
                  f"repeat-phase maximum {max(repeat_gaps, default=0)} ms; "
                  f"turn after last repeat {tail_angle:.2f} degrees", flush=True)
            print(f"changing frames during turning: {len(frames)} in {last-start-650} ms; "
                  f"mean interval {sum(intervals)/len(intervals) if intervals else 0:.2f} ms; "
                  f"maximum interval {max(intervals, default=0)} ms", flush=True)
            check(bool(repeat_gaps) and max(repeat_gaps) < 100,
                  "held turning is continuous after repeats begin")
            check(b"\x1b[>11u" in output, "standalone requests modern keyboard event reporting")
            # Emulate the modern terminal's response, then physical press and
            # release. These are protocol bytes, not replacements for engine logic.
            os.write(master, b"\x1b[?11u")
            wait(0.05)
            before = samples()[-1][1]
            start = ticks()
            os.write(master, b"\x1b[1;1:1C")
            wait(0.05)
            released_at = ticks()
            os.write(master, b"\x1b[1;1:3C")
            wait(0.15)
            angle = ((before - samples()[-1][1]) & 0xffffffff) * 360 / 2**32
            turn_events = [e for e in events() if e[0] >= start and e[2] == 0xae]
            release_latency = turn_events[-1][0] - released_at if turn_events else None
            check([e[1] for e in turn_events] == [1, 0] and angle <= 12
                  and release_latency is not None and release_latency < 60,
                  f"modern 50 ms arrow tap: {angle:.2f} degrees; release {release_latency} ms")
            start = ticks()
            os.write(master, b"\x1b[1;1:1C")
            wait(0.9)  # no repeats: a real hold must not expire at 700 ms
            for _ in range(15):
                os.write(master, b"\x1b[1;1:2C")
                wait(0.04)
            released_at = ticks()
            os.write(master, b"\x1b[1;1:3C")
            wait(0.12)
            rows = samples()
            turning = [row for row, prev in zip(rows[1:], rows[:-1])
                       if start <= row[0] <= released_at and row[1] != prev[1]]
            gaps = [b[0] - a[0] for a, b in zip(turning, turning[1:])]
            ups = [e[0] for e in events() if e[0] >= start and e[1:] == (0, 0xae)]
            check(len(turning) >= 40 and max(gaps, default=1000) < 70
                  and len(ups) == 1 and released_at <= ups[0] < released_at + 60,
                  f"modern hold: {len(turning)} turning ticks; max gap {max(gaps, default=0)} ms; "
                  f"release {ups[0]-released_at if ups else None} ms")
            frames = [t for t in frame_times if start + 200 <= t <= released_at]
            intervals = [b - a for a, b in zip(frames, frames[1:])]
            print(f"modern changing frames: {len(frames)} over {released_at-start-200} ms; "
                  f"mean {sum(intervals)/len(intervals) if intervals else 0:.2f} ms; "
                  f"max {max(intervals, default=0)} ms", flush=True)
            check(len(frames) >= 30, "modern continuous turning produces changing frames")
            drawn = [int(line.split()[0]) for line in frame_trace.read_text().splitlines()
                     if start + 200 <= int(line.split()[0]) <= released_at]
            cadence = [b - a for a, b in zip(drawn, drawn[1:])]
            check(len(drawn) >= 35 and max(cadence, default=1000) < 100,
                  f"engine frame cadence: {len(drawn)} draws; "
                  f"mean {sum(cadence)/len(cadence) if cadence else 0:.2f} ms; "
                  f"max {max(cadence, default=0)} ms")
            # A modern terminal can have a substantially larger fullscreen
            # surface than the resized 80x24 case above. Measure delivered frames,
            # not only calls that return without completing pending output.
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 60, 200, 0, 0))
            proc.send_signal(signal.SIGWINCH)
            resize_offset = len(output)
            wait(0.3)
            repaints = re.findall(rb"\x1b\[\?2026h(.*?)\x1b\[\?2026l",
                                  output[resize_offset:], re.DOTALL)
            full_frames = [f for f in repaints if b"\x1b[2J" in f]
            check(any(f.count("▀".encode()) == 200 * 60 for f in full_frames),
                  "resize uses all 200x60 cells at 200x120 text-pixel resolution")
            start = ticks()
            os.write(master, b"\x1b[1;1:1C")
            wait(1.5)
            released_at = ticks()
            os.write(master, b"\x1b[1;1:3C")
            wait(0.15)
            frames = [t for t in frame_times if start + 200 <= t <= released_at]
            intervals = [b - a for a, b in zip(frames, frames[1:])]
            mean = sum(intervals) / len(intervals) if intervals else 1000
            check(len(frames) >= 25 and mean < 50 and max(intervals, default=1000) < 120,
                  f"large 200x60 surface: {len(frames)} changing frames; "
                  f"mean {mean:.2f} ms; max {max(intervals, default=0)} ms")
            resize_offset = len(output)
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 600, 0, 0))
            proc.send_signal(signal.SIGWINCH)
            wait(0.4)
            repaints = re.findall(rb"\x1b\[\?2026h(.*?)\x1b\[\?2026l",
                                  output[resize_offset:], re.DOTALL)
            check(any(b"\x1b[2J" in f and f.count("▀".encode()) == 600 * 24 for f in repaints),
                  "wide terminal uses every column beyond the old 512-column cap")
            start = ticks()
            os.write(master, b"\x1b[" + b"1" * 100 + b"u\x1b[?1;2C")
            wait(0.1)
            unwanted = [e for e in events() if e[0] >= start and e[1] == 1]
            check(not unwanted, "oversized and unknown terminal reports do not become game keys")
            start = ticks()
            os.write(master, b"\x1b[119;1:1u\x1b[1;1:1A")  # w and Up alias the same DOOM key
            wait(0.08)
            os.write(master, b"\x1b[119;1:3u")
            wait(0.15)
            early_ups = [e for e in events() if e[0] >= start and e[1:] == (0, 0xad)]
            check(not early_ups, "releasing w preserves a simultaneously held Up arrow")
            os.write(master, b"\x1b[1;1:3A")
            wait(0.08)
            ups = [e for e in events() if e[0] >= start and e[1:] == (0, 0xad)]
            check(len(ups) == 1, "aliased movement releases once the last physical key comes up")
            # Event reporting can be supported without the all-keys flag:
            # ordinary letter presses then remain plain UTF-8, but release is CSI.
            os.write(master, b"\x1b[?3u")
            start = ticks()
            os.write(master, b"w")
            wait(0.9)
            premature = [e for e in events() if e[0] >= start and e[1:] == (0, 0xad)]
            check(not premature, "negotiated event reporting keeps a plain letter held until release")
            os.write(master, b"\x1b[119;1:3u\x1b[?11u")
            wait(0.1)
            start = ticks()
            for part in [b"\x1b[", b"113;1:", b"1u"]:
                os.write(master, part)
                wait(0.04)
            os.write(master, b"\x1b[113;1:3u")
            wait(0.08)
            left = [e[1] for e in events() if e[0] >= start and e[2] == 0xac]
            check(left == [1, 0], "modern letter press/release survives split PTY reads")
            # Leave through DOOM's own menu so its atexit handler must restore
            # the terminal keyboard mode, rather than relying on PTY teardown.
            for press_code, release_code in [(b"27;1:1u", b"27;1:3u"),
                                             (b"1;1:1A", b"1;1:3A"),
                                             (b"13;1:1u", b"13;1:3u")]:
                os.write(master, b"\x1b[" + press_code)
                wait(0.05)
                os.write(master, b"\x1b[" + release_code)
                wait(0.05)
            os.write(master, b"\x1b[121;1:1u")
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline:
                if select.select([master], [], [], 0.02)[0]:
                    try:
                        output.extend(os.read(master, 65536))
                    except OSError:
                        break
                elif proc.poll() is not None:
                    break
            check(proc.wait(timeout=2) == 0 and b"\x1b[<u" in output,
                  "normal game exit restores the terminal keyboard mode")
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
