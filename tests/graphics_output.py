#!/usr/bin/env python3
"""Run real DOOM in a PTY and emulate terminal graphics capability replies."""
import base64
import fcntl
import os
from pathlib import Path
import pty
import re
import select
import signal
import struct
import subprocess
import tempfile
import termios
import time
import zlib

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / 'engine/src/build-thurbox'


def digest(data):
    value = 2166136261
    for byte in data:
        value = ((value ^ byte) * 16777619) & 0xffffffff
    return value


def decode_sixel(data, width, height):
    pixels = bytearray(width * height * 3)
    palette = {}
    colour = x = y = pos = 0

    def integer():
        nonlocal pos
        start = pos
        while pos < len(data) and 48 <= data[pos] <= 57:
            pos += 1
        return int(data[start:pos])

    while pos < len(data):
        code = data[pos]; pos += 1
        if code == ord('"'):
            for _ in range(4):
                integer()
                if pos < len(data) and data[pos] == ord(';'): pos += 1
        elif code == ord('#'):
            colour = integer()
            if pos < len(data) and data[pos] == ord(';'):
                values = []
                while pos < len(data) and data[pos] == ord(';'):
                    pos += 1; values.append(integer())
                assert values[0] == 2 and len(values) == 4
                palette[colour] = bytes(v * 255 // 100 for v in values[1:])
        elif code == ord('$'):
            x = 0
        elif code == ord('-'):
            x = 0; y += 6
        else:
            count = 1
            if code == ord('!'):
                count = integer(); code = data[pos]; pos += 1
            assert 63 <= code <= 126
            bits = code - 63
            for bit in range(6):
                if bits & (1 << bit) and y + bit < height:
                    begin = ((y + bit) * width + x) * 3
                    pixels[begin:begin + count * 3] = palette[colour] * count
            x += count
    # Sample one output pixel corresponding to each native source pixel.
    native = bytearray()
    for sy in range(400):
        py = (sy * height + 399) // 400
        for sx in range(640):
            px = (sx * width + 639) // 640
            index = (py * width + px) * 3
            native.extend(pixels[index:index+3])
    return native


def run(mode):
    with tempfile.TemporaryDirectory(prefix='graphics-', dir=BUILD) as scratch:
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 100, 800, 640))
        scratch = Path(scratch)
        binary = scratch/'doom-traced'
        objects = sorted(str(p) for p in BUILD.glob('*.o'))
        subprocess.run(['cc', '-O2', '-I'+str(ROOT/'engine/src'), str(ROOT/'tests/input_trace.c'),
                        *objects, '-Wl,--wrap=DG_GetKey', '-Wl,--wrap=M_Responder',
                        '-Wl,--wrap=G_Ticker', '-Wl,--wrap=DG_DrawFrame', '-lm', '-o', str(binary)], check=True)
        env = dict(os.environ, DOOM_PIXEL_TRACE=str(scratch/'pixels'), DOOM_FRAME_TRACE=str(scratch/'frames'),
                   DOOM_INPUT_TRACE=str(scratch/'events'), DOOM_TICK_TRACE=str(scratch/'ticks'),
                   DOOM_MENU_TRACE=str(scratch/'menu'))
        args = ['-cells'] if mode == 'cells' else []
        proc = subprocess.Popen([str(binary), *args, '-iwad', str(ROOT/'wad/doom1.wad'),
                                 '-warp', '1', '1', '-nomonsters', '-config', str(Path(scratch)/'config')],
                                stdin=slave, stdout=slave, stderr=slave, cwd=scratch, env=env)
        os.close(slave)
        output = bytearray()
        frame_times = []
        frame_end = 0

        def wait(seconds):
            nonlocal frame_end
            end = time.monotonic() + seconds
            while time.monotonic() < end:
                if select.select([master], [], [], .002)[0]:
                    output.extend(os.read(master, 65536))
                    while True:
                        finish = output.find(b'\x1b[?2026l', frame_end)
                        if finish < 0: break
                        finish += 8
                        if finish - frame_end > 16: frame_times.append(time.monotonic())
                        frame_end = finish
                if proc.poll() is not None:
                    raise AssertionError('engine exited')

        try:
            wait(.8)
            assert b'a=q' in output and b'\x1b[c' in output, 'missing terminal graphics capability queries'
            if mode in ['kitty', 'cells']:
                # Exercise an APC response split across PTY reads.
                for part in [b'\x1b_Gi=31;', b'OK\x1b', b'\\']:
                    os.write(master, part)
                    wait(.03)
            else:
                os.write(master, b'\x1b[?64;4c\x1b[4;640;800t')
            os.write(master, b'\x1b[?11u\x1b[1;1:1C')
            start = len(output)
            start_clock = time.monotonic()
            wait(1.2)
            frames = bytes(output[start:])
            if mode == 'cells':
                assert '▀'.encode() in frames and b'a=T' not in frames, 'forced cells unexpectedly selected images'
                print('PASS -cells preserves text rendering despite Kitty capability response', flush=True)
            elif mode == 'kitty':
                chunks = re.findall(rb'\x1b_G([^;]+);([^\x1b]*)\x1b\\', frames)
                first = next(i for i, (header, _) in enumerate(chunks) if b'a=T' in header)
                header = dict(field.split(b'=', 1) for field in chunks[first][0].split(b','))
                assert (header[b's'], header[b'v'], header[b'c'], header[b'r']) == (b'640', b'400', b'100', b'40'), header
                payload = bytearray()
                for controls, data in chunks[first:]:
                    assert len(data) <= 4096, 'Kitty payload exceeds protocol chunk limit'
                    payload.extend(data)
                    if b'm=0' in controls:
                        break
                rgb = zlib.decompress(base64.b64decode(payload))
                assert len(rgb) == 640 * 400 * 3 and len(set(rgb)) > 16, 'missing full RGB game framebuffer'
                hashes = [int(row.split()[0]) for row in (scratch/'pixels').read_text().splitlines()]
                assert digest(rgb) in hashes, 'Kitty image differs from the actual DOOM framebuffer'
                print('PASS Kitty: full 640x400 RGB framebuffer scaled to all 100x40 cells', flush=True)
            else:
                image = re.search(rb'\x1bP0;1;0q(.*?)\x1b\\', frames, re.DOTALL)
                assert image, 'no Sixel game frame after supported DA response'
                assert image[1].startswith(b'"1;1;800;640'), 'Sixel does not use terminal pixel dimensions'
                assert b'#' in image[1] and b'!' in image[1], 'missing palette or run encoding'
                native = decode_sixel(image[1], 800, 640)
                hashes = [int(row.split()[1]) for row in (scratch/'pixels').read_text().splitlines()]
                assert digest(native) in hashes, 'Sixel image differs from the actual DOOM framebuffer'
                print('PASS Sixel: image uses reported 800x640 terminal pixel viewport', flush=True)
            delivered = [t for t in frame_times if t >= start_clock + .2]
            gaps = [(b-a)*1000 for a,b in zip(delivered,delivered[1:])]
            assert len(delivered) >= 20 and max(gaps, default=1000) < 100, (mode, len(delivered), gaps)
            print(f'PASS {mode} turning: {len(delivered)} frames; max gap {max(gaps):.1f} ms', flush=True)
            os.write(master, b'\x1b[1;1:3C')
            wait(.1)
            start_time = int(time.monotonic() * 1000) & 0xffffffff
            os.write(master, b'\x1b[102;1:1u')
            time.sleep(.35)  # leave a full graphics frame blocked in the PTY
            events = [list(map(int, row.split())) for row in (scratch/'events').read_text().splitlines()]
            fire = [row for row in events if row[0] >= start_time and row[1:] == [1, 0xa3]]
            assert fire and fire[0][0] - start_time < 100, 'graphics output blocked keyboard input'
            print(f'PASS {mode} blocked output: fire received in {fire[0][0] - start_time} ms', flush=True)
            wait(.2)
            start = len(output)
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 120, 960, 480))
            proc.send_signal(signal.SIGWINCH)
            wait(.5)
            resized = bytes(output[start:])
            if mode == 'kitty':
                assert re.search(rb'a=T,[^;]*c=120,r=30', resized), 'Kitty placement did not resize'
            elif mode == 'sixel':
                assert b'\x1b[14t' in resized, 'Sixel did not refresh pixel geometry on resize'
                assert b'\x1bP0;1;0q"1;1;960;480' in resized, 'Sixel viewport did not resize'
            else:
                frames = re.findall(rb'\x1b\[\?2026h(.*?)\x1b\[\?2026l', resized, re.DOTALL)
                assert any(b'\x1b[2J' in f and f.count('▀'.encode()) == 120*30 for f in frames)
            print(f'PASS {mode} resize uses the new terminal viewport', flush=True)
            # Terminate through the real game menu and verify both protocol modes
            # and image cleanup, rather than relying on tearing down the PTY.
            os.write(master, b'\x1b[?11u')
            for down, up in [(b'27;1:1u', b'27;1:3u'), (b'1;1:1A', b'1;1:3A'),
                             (b'13;1:1u', b'13;1:3u')]:
                os.write(master, b'\x1b['+down); wait(.05)
                os.write(master, b'\x1b['+up); wait(.05)
            os.write(master, b'\x1b[121;1:1u')
            deadline = time.monotonic()+2
            while time.monotonic() < deadline:
                if select.select([master], [], [], .02)[0]:
                    try: output.extend(os.read(master, 65536))
                    except OSError: break
                elif proc.poll() is not None: break
            assert proc.wait(timeout=2) == 0 and b'\x1b[<u' in output
            assert b'\x1b[?80r' in output and b'a=d,d=I,i=32' in output
            print(f'PASS {mode} normal exit restores keyboard/Sixel modes and deletes its image', flush=True)
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                proc.kill(); proc.wait()
            os.close(master)


if __name__ == '__main__':
    for mode in ['kitty', 'sixel', 'cells']:
        run(mode)
