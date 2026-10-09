#!/usr/bin/env python3
"""Optional Linux test: physical keys in Ghostty on a private Xvfb display.

Requires Ghostty, Xvfb, X11/XTest libraries, ffmpeg, make and a C compiler.
Writes comparison clips and measurements under the ignored engine build directory.
It does not connect to the user's display or terminal and closes its own processes.
"""
import ctypes as C
import json
import os
from pathlib import Path
import signal
import subprocess as S
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
BASELINE = '7061cb1d803d837d18b356cae5feed22bd665e28'
BUILD = ROOT / 'engine/src/build-thurbox'
S.run(['make','-C',str(ROOT/'engine/src'),'-s','doom'],check=True)
X = C.CDLL('libX11.so.6')
T = C.CDLL('libXtst.so.6')
ptr = C.c_void_p
ul = C.c_ulong
for name, args, result in [
    ('XOpenDisplay',[C.c_char_p],ptr),('XDefaultRootWindow',[ptr],ul),
    ('XQueryTree',[ptr,ul,C.POINTER(ul),C.POINTER(ul),C.POINTER(C.POINTER(ul)),C.POINTER(C.c_uint)],C.c_int),
    ('XFetchName',[ptr,ul,C.POINTER(C.c_char_p)],C.c_int),
    ('XSetInputFocus',[ptr,ul,C.c_int,ul],C.c_int),
    ('XKeysymToKeycode',[ptr,ul],C.c_uint),('XFlush',[ptr],C.c_int),
    ('XAutoRepeatOff',[ptr],C.c_int),('XCloseDisplay',[ptr],C.c_int),('XFree',[ptr],C.c_int)]:
    fn = getattr(X,name); fn.argtypes=args; fn.restype=result
T.XTestFakeKeyEvent.argtypes=[ptr,C.c_uint,C.c_int,ul]
T.XTestFakeKeyEvent.restype=C.c_int

with tempfile.TemporaryDirectory(prefix='ghostty-',dir=BUILD) as scratch_name:
    scratch=Path(scratch_name)
    rfd,wfd=os.pipe()
    xvfb=S.Popen(['Xvfb','-displayfd',str(wfd),'-screen','0','1024x768x24','-nolisten','tcp'],pass_fds=[wfd],stdout=S.DEVNULL,stderr=S.DEVNULL)
    os.close(wfd)
    display=':'+os.read(rfd,32).decode().strip();os.close(rfd)
    connection=X.XOpenDisplay(display.encode())
    assert connection,'no virtual display'
    X.XAutoRepeatOff(connection);X.XFlush(connection)
    report={}
    movies=[]
    try:
        for label in ['original','fixed']:
            run=scratch/label;run.mkdir()
            binary=run/'doom-traced'
            objects=sorted(str(p) for p in BUILD.glob('*.o'))
            if label=='original':
                source=run/'frontend.c'
                source.write_bytes(S.check_output(['git','show',BASELINE+':engine/src/doomgeneric_thurbox.c'],cwd=ROOT))
                obj=run/'frontend.o'
                S.run(['cc','-O2','-D_DEFAULT_SOURCE','-I'+str(ROOT/'engine/src'),'-c',str(source),'-o',str(obj)],check=True)
                objects=[p for p in objects if not p.endswith('/doomgeneric_thurbox.o')]+[str(obj)]
            S.run(['cc','-O2','-I'+str(ROOT/'engine/src'),str(ROOT/'tests/input_trace.c'),*objects,
                   '-Wl,--wrap=DG_GetKey','-Wl,--wrap=M_Responder','-Wl,--wrap=G_Ticker','-Wl,--wrap=DG_DrawFrame',
                   '-lm','-o',str(binary)],check=True)
            env=dict(os.environ,DISPLAY=display,GDK_BACKEND='x11',LIBGL_ALWAYS_SOFTWARE='1',
                     XDG_CONFIG_HOME=str(run/'config'),DOOM_INPUT_TRACE=str(run/'events'),
                     DOOM_MENU_TRACE=str(run/'menu'),DOOM_TICK_TRACE=str(run/'ticks'),DOOM_FRAME_TRACE=str(run/'frames'))
            stderr=open(run/'ghostty.log','w')
            ghost=S.Popen(['ghostty','--gtk-single-instance=false','--title=DOOM input test',
                           '--confirm-close-surface=false','--window-width=100','--window-height=36',
                           '--font-size=10','-e',str(binary),'-iwad',str(ROOT/'wad/doom1.wad'),'-warp','1','1',
                           '-nomonsters','-config',str(run/'doom.cfg')],env=env,stdout=S.DEVNULL,stderr=stderr)
            try:
                deadline=time.monotonic()+8
                while not (run/'ticks').exists() and time.monotonic()<deadline:
                    if ghost.poll() is not None:
                        raise RuntimeError((run/'ghostty.log').read_text())
                    time.sleep(.05)
                assert (run/'ticks').exists(),(run/'ghostty.log').read_text()
                time.sleep(1.2)
                root=X.XDefaultRootWindow(connection)
                rr,pp,n=ul(),ul(),C.c_uint();children=C.POINTER(ul)()
                X.XQueryTree(connection,root,C.byref(rr),C.byref(pp),C.byref(children),C.byref(n))
                window=None
                for i in range(n.value):
                    name=C.c_char_p()
                    if X.XFetchName(connection,children[i],C.byref(name)) and name.value:
                        title=name.value.decode(errors='replace')
                        if title=='DOOM input test':window=children[i]
                        X.XFree(C.cast(name,ptr))
                X.XFree(C.cast(children,ptr));assert window,'no Ghostty window'
                X.XSetInputFocus(connection,window,1,0);X.XFlush(connection)
                key=X.XKeysymToKeycode(connection,0xff53)
                def angle():
                    return int((run/'ticks').read_text().splitlines()[-1].split()[1])
                before=angle()
                movie=run/'tap.mkv'
                recorder=S.Popen(['ffmpeg','-hide_banner','-loglevel','error','-y','-f','x11grab',
                                   '-video_size','1024x768','-framerate','35','-i',display,
                                   '-t','1.2','-c:v','libx264','-preset','ultrafast',str(movie)],stdout=S.DEVNULL,stderr=S.PIPE)
                time.sleep(.2)
                T.XTestFakeKeyEvent(connection,key,1,0);X.XFlush(connection)
                time.sleep(.05)
                released=int(time.monotonic()*1000)&0xffffffff
                T.XTestFakeKeyEvent(connection,key,0,0);X.XFlush(connection)
                time.sleep(.9)
                delta=((before-angle())&0xffffffff)*360/2**32
                ups=[list(map(int,line.split())) for line in (run/'events').read_text().splitlines() if line.split()[1:] == ['0','174']]
                latency=ups[-1][0]-released if ups else None
                recorder.communicate(timeout=3);assert recorder.returncode==0
                saved=BUILD/(label+'-tap.mkv');saved.write_bytes(movie.read_bytes());movies.append(saved)
                start=int(time.monotonic()*1000)&0xffffffff
                T.XTestFakeKeyEvent(connection,key,1,0);X.XFlush(connection)
                time.sleep(.9)
                end=int(time.monotonic()*1000)&0xffffffff
                T.XTestFakeKeyEvent(connection,key,0,0);X.XFlush(connection)
                time.sleep(.15)
                rows=[list(map(int,line.split())) for line in (run/'ticks').read_text().splitlines()]
                turning=[row for row,prev in zip(rows[1:],rows[:-1]) if start<=row[0]<=end and row[1]!=prev[1]]
                downs=[list(map(int,line.split())) for line in (run/'events').read_text().splitlines() if line.split()[1:] == ['1','174']]
                report[label]={'tap_degrees':round(delta,2),'release_latency_ms':latency,
                               'hold_turning_ticks':len(turning),'hold_last_turn_ms':turning[-1][0]-start if turning else None}
                print(label,json.dumps(report[label]),flush=True)
                if label=='fixed':
                    assert delta<=12 and latency is not None and 0<=latency<80,report
                    assert len(turning)>=29 and turning[-1][0]>=end-60,report
            finally:
                ghost.terminate()
                try:ghost.wait(timeout=3)
                except S.TimeoutExpired:ghost.kill();ghost.wait()
                stderr.close()
        (BUILD/'ghostty-report.json').write_text(json.dumps(report,indent=2))
    finally:
        X.XCloseDisplay(connection)
        xvfb.terminate();xvfb.wait(timeout=3)

# Record a portable before/after demo from the physical-key captures.
filters = []
for index, label in enumerate(['original', 'fixed']):
    caption = ('Original' if index == 0 else 'Modern releases')
    caption += f" - {report[label]['tap_degrees']} degrees"
    filters.append(f"[{index}:v]fps=25,crop=820:620:0:0,scale=512:387,"
                   f"drawbox=x=0:y=0:w=iw:h=28:color=black:t=fill,"
                   f"drawtext=text='{caption}':x=10:y=5:fontsize=18:fontcolor=white[v{index}]")
filters.append('[v0][v1]hstack,split[p][q];[p]palettegen[pal];[q][pal]paletteuse')
S.run(['ffmpeg','-hide_banner','-loglevel','error','-y',
       '-i',str(movies[0]),'-i',str(movies[1]),'-filter_complex',';'.join(filters),
       '-loop','0',str(ROOT/'media/input-turning.gif')],check=True)
