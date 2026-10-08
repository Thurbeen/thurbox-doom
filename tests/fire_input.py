#!/usr/bin/env python3
"""Count actual pistol ammunition used by taps and holds in standalone DOOM."""
import fcntl, os, pty, select, struct, subprocess, tempfile, termios, time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
BUILD=ROOT/'engine/src/build-thurbox'

def run(windows=0):
    subprocess.run(['make','-s','-C',str(ROOT/'engine/src'),'doom'],check=True)
    with tempfile.TemporaryDirectory(prefix='fire-',dir=BUILD) as scratch:
        scratch=Path(scratch); binary=scratch/'doom-traced'
        subprocess.run(['cc','-O2','-I'+str(ROOT/'engine/src'),str(ROOT/'tests/input_trace.c'),
                        *map(str,sorted(BUILD.glob('*.o'))),'-Wl,--wrap=DG_GetKey',
                        '-Wl,--wrap=M_Responder','-Wl,--wrap=G_Ticker','-Wl,--wrap=DG_DrawFrame',
                        '-lm','-o',str(binary)],check=True)
        master,slave=pty.openpty()
        fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',24,80,0,0))
        env=dict(os.environ,**{'DOOM_'+key+'_TRACE':str(scratch/name) for key,name in
                 [('INPUT','keys'),('MENU','menu'),('TICK','ticks'),('FRAME','frames'),('MOUSE_PLAYER','player')]})
        proc=subprocess.Popen([str(binary),'-cells','-nomouse','-iwad',str(ROOT/'wad/doom1.wad'),
                               '-warp','1','1','-nomonsters','-config',str(scratch/'config')],
                              stdin=slave,stdout=slave,stderr=slave,cwd=scratch,env=env)
        os.close(slave)
        output=bytearray()
        def wait(seconds,exiting=False):
            end=time.monotonic()+seconds
            while time.monotonic()<end:
                if select.select([master],[],[],.002)[0]:
                    try: output.extend(os.read(master,65536))
                    except OSError:
                        if exiting: break
                        raise
                if exiting and proc.poll() is not None: break
                assert proc.poll() is None,'engine exited'
        def ammo(): return int((scratch/'player').read_text().splitlines()[-1].split()[4])
        def check(shots,label):
            assert shots==1,f'{label}: expected one pistol shot, observed {shots}'
            print(f'PASS {label}: {shots} pistol shot',flush=True)
        try:
            wait(1.4)
            if windows:
                assert b'\x1b[?9001$p' in output, 'missing Windows Terminal key-release capability query'
                os.write(master,f'\x1b[?9001;{windows}$y'.encode()); wait(.15)
                assert (b'\x1b[?9001h' in output)==(windows==2), 'Win32 mode does not match initial capability state'
                os.write(master,b'\x1b[115;62;0;1;0;1_'); wait(.1)
                assert int((scratch/'player').read_text().splitlines()[-1].split()[2])==0, 'Win32 F4 becomes backward movement'
                count=len((scratch/'keys').read_text().splitlines())
                os.write(master,b'\x1b[9999999999999;0;102;1;0;1_\x1b[70;33;102;2;0;1_\x1b[70;33;102;1;0;0_'); wait(.1)
                assert len((scratch/'keys').read_text().splitlines())==count, 'malformed Win32 records become game keys'
                print('PASS Win32 function keys do not become movement',flush=True)
                before=ammo(); os.write(master,b'\x1b[70;33;'); wait(.02)
                os.write(master,b'102;1;0;1_'); wait(.05)
                os.write(master,b'\x1b[70;33;0;0;0;1_'); wait(.9)
                check(before-ammo(),'Win32 50ms f tap with zero-character release')
                angles=lambda: [tuple(map(int,row.split())) for row in (scratch/'ticks').read_text().splitlines()]
                before=angles()[-1][1]
                os.write(master,b'\x1b[39;77;0;1;256;1_'); wait(.05)
                os.write(master,b'\x1b[39;77;0;0;256;1_'); wait(.15)
                turn=((before-angles()[-1][1])&0xffffffff)*360/2**32
                assert 0<turn<8,f'Win32 arrow tap turns {turn:.2f} degrees'
                print(f'PASS Win32 arrow tap: {turn:.2f} degrees',flush=True)
                start=time.monotonic()*1000
                os.write(master,b'\x1b[39;77;0;1;256;1_'); wait(.95)
                rows=angles(); changes=[row for row,prev in zip(rows[1:],rows[:-1]) if row[0]>=int(start)&0xffffffff and row[1]!=prev[1]]
                assert len(changes)>=28,'Win32 no-repeat hold expires early'
                os.write(master,b'\x1b[39;77;0;0;256;1_'); wait(.1); stopped=angles()[-1][1]; wait(.2)
                assert angles()[-1][1]==stopped,'Win32 turn continues after release'
                print(f'PASS Win32 hold: {len(changes)} turning ticks, stops on release',flush=True)
                # Each physical Shift releases independently, even with generic VK_SHIFT.
                os.write(master,b'\x1b[16;42;0;1;16;1_\x1b[16;54;0;1;16;1_'); wait(.05)
                count=len((scratch/'keys').read_text().splitlines())
                os.write(master,b'\x1b[16;42;0;0;16;1_'); wait(.05)
                assert len((scratch/'keys').read_text().splitlines())==count,'one Shift release releases the other'
                os.write(master,b'\x1b[16;54;0;0;0;1_'); wait(.05)
                assert (scratch/'keys').read_text().splitlines()[-1].split()[1:]==['0','182'],'final Shift release lost'
                print('PASS Win32 physical Shift aliases release independently',flush=True)
                for report in [b'27;1:1u',b'27;1:3u',b'1;1:1A',b'1;1:3A',b'13;1:1u',b'13;1:3u']:
                    os.write(master,b'\x1b['+report); wait(.05)
                os.write(master,b'\x1b[121;1:1u'); wait(2,True)
                assert proc.wait(timeout=2)==0
                assert (b'\x1b[?9001l' in output)==(windows==2),'Win32 mode is not restored to its initial state'
                print(f'PASS normal exit restores Win32 mode initially {windows}',flush=True)
                return
            os.write(master,b'\x1b[?9001;0$y'); wait(.05)
            assert b'\x1b[?9001h' not in output,'unsupported Win32 mode enabled'
            for tap in range(2):
                before=ammo(); os.write(master,b'f'); wait(.95)
                check(before-ammo(),f'plain f tap {tap+1}')
            os.write(master,b'\x1b[?11u'); wait(.05)
            before=ammo(); os.write(master,b'\x1b[102;1:1u'); wait(.05)
            os.write(master,b'\x1b[102;1:3u'); wait(.9)
            check(before-ammo(),'modern 50ms f tap')
            before=ammo(); os.write(master,b'\x1b[102;1:1u'); wait(.95)
            shots=before-ammo(); assert shots>=2,f'real held f does not sustain fire: {shots}'
            os.write(master,b'\x1b[102;1:3u'); wait(.1); stopped=ammo(); wait(.65)
            assert ammo()==stopped,'new pistol shot after physical f release'
            print(f'PASS modern held f: {shots} shots, no new shots after release',flush=True)
        finally:
            if proc.poll() is None: proc.terminate(); proc.wait(timeout=3)
            os.close(master)

if __name__=='__main__': run(); run(2); run(1)
