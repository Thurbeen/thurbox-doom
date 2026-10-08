#!/usr/bin/env python3
"""Real standalone engine, SGR mouse reports, native responder and player yaw."""
import fcntl, os, pty, select, signal, struct, subprocess, tempfile, termios, time
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / 'engine/src/build-thurbox'

def run(disabled=False):
    with tempfile.TemporaryDirectory(prefix='mouse-', dir=BUILD) as scratch:
        scratch = Path(scratch)
        binary = scratch/'doom-traced'
        subprocess.run(['cc', '-O2', '-DDOOM_MOUSE_TRACE_WRAPPER', '-I'+str(ROOT/'engine/src'), str(ROOT/'tests/input_trace.c'),
                        *map(str, sorted(BUILD.glob('*.o'))), '-Wl,--wrap=DG_GetKey',
                        '-Wl,--wrap=M_Responder', '-Wl,--wrap=G_Ticker', '-Wl,--wrap=DG_DrawFrame',
                        '-Wl,--wrap=G_Responder', '-lm', '-o', str(binary)], check=True)
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH',40,100,800,640))
        env = dict(os.environ, **{'DOOM_'+key+'_TRACE':str(scratch/name) for key,name in
                   [('INPUT','keys'),('MENU','menu'),('TICK','ticks'),('FRAME','frames'),('MOUSE','mouse'),('MOUSE_PLAYER','player')]})
        proc = subprocess.Popen([str(binary), '-cells', *(['-nomouse'] if disabled else []),
                                 '-iwad', str(ROOT/'wad/doom1.wad'), '-warp','1','1','-nomonsters',
                                 '-config',str(scratch/'config')], cwd=scratch, env=env,
                                stdin=slave, stdout=slave, stderr=slave)
        os.close(slave); output=bytearray()
        def wait(seconds, drain=True):
            end=time.monotonic()+seconds
            while time.monotonic()<end:
                if drain and select.select([master],[],[],.002)[0]: output.extend(os.read(master,65536))
                elif not drain: time.sleep(.002)
                assert proc.poll() is None, 'engine exited'
        def send(report): os.write(master,report); wait(.09)
        def events():
            return [list(map(int,row.split())) for row in (scratch/'mouse').read_text().splitlines()] if (scratch/'mouse').exists() else []
        def player(): return list(map(int,(scratch/'player').read_text().splitlines()[-1].split()))
        def angle(): return int((scratch/'ticks').read_text().splitlines()[-1].split()[1])
        try:
            wait(1.4)
            assert (b'\x1b[?1003h' in output) != disabled, 'missing all-motion mouse reporting request'
            assert (b'\x1b[?1006h' in output) != disabled, 'missing SGR coordinates request'
            send(b'\x1b[<35;50;20M')
            if disabled:
                assert not events(), '-nomouse still feeds native mouse events'
                print('PASS -nomouse preserves keyboard-only operation',flush=True)
                return
            before=angle()
            # Split reads and several motions in one engine poll: preserve their sum.
            os.write(master,b'\x1b[<35;'); wait(.02)
            send(b'51;20M\x1b[<35;52;20M\x1b[<35;53;20M')
            assert events(), 'SGR motion never reaches native engine responder'
            assert events()[-1][2:]==[24,0], events() # 8 native units / cell
            delta=min((angle()-before)&0xffffffff,(before-angle())&0xffffffff)*360/2**32
            assert .9<delta<1.2, f'3-cell mouse turn is {delta:.3f} degrees'
            print(f'PASS 3-cell mouse motion turns actual player {delta:.3f} degrees',flush=True)
            stopped=angle(); wait(.2); assert angle()==stopped,'mouse keeps turning after motion stops'
            print('PASS split/batched motion turns real player once and stops without a timeout',flush=True)
            send(b'\x1b[<0;53;20M'); assert events()[-1][1]==1 and player()[1]&1,'left button does not fire'
            send(b'\x1b[<2;53;20M'); assert events()[-1][1]==3,'right press loses held left button'
            before=angle(); player_start=len((scratch/'player').read_text().splitlines()); send(b'\x1b[<34;54;20M')
            sides=[int(row.split()[3]) for row in (scratch/'player').read_text().splitlines()[player_start:]]
            assert any(side>0 for side in sides) and angle()==before, 'right-drag must strafe instead of turning'
            send(b'\x1b[<0;53;20m'); assert events()[-1][1]==2,'left release loses held right button'
            send(b'\x1b[<2;53;20m'); assert events()[-1][1]==0 and not player()[1]&1,'mouse buttons stick after release'
            send(b'\x1b[<1;53;20M'); assert player()[2]>0,'middle button does not move forward'
            send(b'\x1b[<1;53;20m'); assert player()[2]==0,'forward motion sticks after release'
            print('PASS native fire/strafe buttons retain independent press and release state',flush=True)
            send(b'\x1b[<0;53;20M\x1b[119;1:1u'); assert player()[2]>0
            send(b'\x1b[O')
            assert events()[-1][1]==0 and not player()[1]&1 and player()[2]==0,'fire or movement stays held when terminal loses focus'
            print('PASS focus loss releases held mouse buttons',flush=True)
            send(b'\x1b[I\x1b[<35;53;20M')
            count=len(events()); send(b'\x1b[<999;1;1M\x1b[<0;0;1M\x1b[<0;99999999999999;1M\x1b[<0;+1;1M\x1b[<0;4294967297;1M')
            assert len(events())==count,'invalid report reaches engine'
            print('PASS invalid mouse reports are discarded',flush=True)
            wait(.1,False); start=int(time.monotonic()*1000)&0xffffffff; os.write(master,b'\x1b[<0;53;20M'); wait(.15,False)
            assert events()[-1][1]==1,'blocked output prevents mouse fire'
            latency=(events()[-1][0]-start)&0xffffffff
            assert latency<100, f'mouse input delayed {latency}ms'
            print(f'PASS blocked-output mouse fire reaches engine in {latency}ms',flush=True)
            send(b'\x1b[<0;53;20m')
            # Normal menu exit must restore the outer terminal modes.
            for key in [b'\x1b[27;1:1u',b'\x1b[27;1:3u',b'\x1b[1;1:1A',b'\x1b[1;1:3A',b'\x1b[13;1:1u',b'\x1b[13;1:3u',b'\x1b[121;1:1u']:
                os.write(master,key)
                end=time.monotonic()+.15
                while time.monotonic()<end and proc.poll() is None:
                    if select.select([master],[],[],.002)[0]:
                        try: output.extend(os.read(master,65536))
                        except OSError: break
            proc.wait(timeout=3)
            while select.select([master],[],[],.01)[0]:
                try: output.extend(os.read(master,65536))
                except OSError: break
            assert b'\x1b[?1003l' in output and b'\x1b[?1006l' in output, 'exit leaves capture enabled in terminals without private-mode restore'
            assert b'\x1b[?1003r' in output and b'\x1b[?1006r' in output,'mouse modes not restored'
            print('PASS normal game exit restores saved mouse modes',flush=True)
        finally:
            if proc.poll() is None: proc.terminate(); proc.wait(timeout=3)
            os.close(master)

if __name__=='__main__':
    subprocess.run(['make','-s','-C',str(ROOT/'engine/src'),'doom'],check=True)
    run(); run(True)
