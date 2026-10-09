#!/usr/bin/env python3
"""Optional physical pointer regression in Ghostty on a private Xvfb display."""
import ctypes as C
import os
from pathlib import Path
import subprocess as S
import tempfile
import time
ROOT=Path(__file__).resolve().parents[1]
BUILD=ROOT/'engine/src/build-thurbox'
BASELINE='b9c556d06bebfe4634e300792ff55f79acf6c8f3'
S.run(['make','-s','-C',str(ROOT/'engine/src'),'doom'],check=True)
X=C.CDLL('libX11.so.6'); T=C.CDLL('libXtst.so.6')
ptr=C.c_void_p; ul=C.c_ulong; ui=C.c_uint; ci=C.c_int
for name,args,result in [
 ('XOpenDisplay',[C.c_char_p],ptr),('XDefaultRootWindow',[ptr],ul),
 ('XQueryTree',[ptr,ul,C.POINTER(ul),C.POINTER(ul),C.POINTER(C.POINTER(ul)),C.POINTER(ui)],ci),
 ('XFetchName',[ptr,ul,C.POINTER(C.c_char_p)],ci),('XFree',[ptr],ci),
 ('XSetInputFocus',[ptr,ul,ci,ul],ci),('XFlush',[ptr],ci),('XCloseDisplay',[ptr],ci),
 ('XGetGeometry',[ptr,ul,C.POINTER(ul),C.POINTER(ci),C.POINTER(ci),C.POINTER(ui),C.POINTER(ui),C.POINTER(ui),C.POINTER(ui)],ci),
 ('XKeysymToKeycode',[ptr,ul],ui)]:
 fn=getattr(X,name); fn.argtypes=args; fn.restype=result
for name,args in [('XTestFakeMotionEvent',[ptr,ci,ci,ci,ul]),('XTestFakeButtonEvent',[ptr,ui,ci,ul]),('XTestFakeKeyEvent',[ptr,ui,ci,ul])]:
 fn=getattr(T,name); fn.argtypes=args; fn.restype=ci
with tempfile.TemporaryDirectory(prefix='ghostty-mouse-',dir=BUILD) as name:
 scratch=Path(name); rfd,wfd=os.pipe(); xvfb_log=(scratch/'xvfb.log').open('w')
 xvfb=S.Popen(['Xvfb','-displayfd',str(wfd),'-screen','0','1280x1024x24','-nolisten','tcp'],pass_fds=[wfd],stdout=S.DEVNULL,stderr=xvfb_log)
 os.close(wfd); display=':'+os.read(rfd,32).decode().strip(); os.close(rfd)
 connection=None
 try:
  for attempt in range(40):
   connection=X.XOpenDisplay(display.encode())
   if connection: break
   time.sleep(.05)
  assert connection,(display,xvfb.poll(),(scratch/'xvfb.log').read_text())

  for label in ['before','fixed']:
   run=scratch/label;run.mkdir(); binary=run/'doom-traced'
   objects=sorted(map(str,BUILD.glob('*.o')))
   if label=='before':
    source=run/'frontend.c';source.write_bytes(S.check_output(['git','show',BASELINE+':engine/src/doomgeneric_thurbox.c'],cwd=ROOT))
    obj=run/'frontend.o';S.run(['cc','-O2','-D_DEFAULT_SOURCE','-I'+str(ROOT/'engine/src'),'-c',str(source),'-o',str(obj)],check=True)
    objects=[p for p in objects if not p.endswith('/doomgeneric_thurbox.o')]+[str(obj)]
   S.run(['cc','-O2','-DDOOM_MOUSE_TRACE_WRAPPER','-I'+str(ROOT/'engine/src'),str(ROOT/'tests/input_trace.c'),*objects,
          '-Wl,--wrap=DG_GetKey','-Wl,--wrap=M_Responder','-Wl,--wrap=G_Ticker','-Wl,--wrap=DG_DrawFrame',
          '-Wl,--wrap=G_Responder','-lm','-o',str(binary)],check=True)
   env=dict(os.environ,DISPLAY=display,GDK_BACKEND='x11',LIBGL_ALWAYS_SOFTWARE='1',XDG_CONFIG_HOME=str(run/'config'),
            **{'DOOM_'+key+'_TRACE':str(run/file) for key,file in [('INPUT','keys'),('MENU','menu'),('TICK','ticks'),('FRAME','frames'),('MOUSE','mouse'),('MOUSE_PLAYER','player')]})
   with (run/'terminal.log').open('w') as log:
    ghost=S.Popen(['ghostty','--gtk-single-instance=false','--title=DOOM pointer test','--confirm-close-surface=false',
                   '--window-width=100','--window-height=36','--font-size=10','-e',str(binary),'-iwad',str(ROOT/'wad/doom1.wad'),
                   '-warp','1','1','-nomonsters','-config',str(run/'doom.cfg')],env=env,stdout=S.DEVNULL,stderr=log)
    try:
     end=time.monotonic()+8
     while not (run/'player').exists() and time.monotonic()<end:
      assert ghost.poll() is None,(run/'terminal.log').read_text(); time.sleep(.05)
     assert (run/'player').exists();time.sleep(1)
     root=X.XDefaultRootWindow(connection); rr,pp,n=ul(),ul(),ui(); children=C.POINTER(ul)()
     X.XQueryTree(connection,root,C.byref(rr),C.byref(pp),C.byref(children),C.byref(n));window=None
     for i in range(n.value):
      title=C.c_char_p()
      if X.XFetchName(connection,children[i],C.byref(title)) and title.value:
       if title.value==b'DOOM pointer test':window=children[i]
       X.XFree(C.cast(title,ptr))
     X.XFree(C.cast(children,ptr));assert window
     x,y,w,h,b,d=ci(),ci(),ui(),ui(),ui(),ui()
     X.XGetGeometry(connection,window,C.byref(rr),C.byref(x),C.byref(y),C.byref(w),C.byref(h),C.byref(b),C.byref(d))
     X.XSetInputFocus(connection,window,1,0);X.XFlush(connection);time.sleep(.2)
     def motion(px): T.XTestFakeMotionEvent(connection,-1,px,y.value+h.value//2,0);X.XFlush(connection);time.sleep(.09)
     def button(down): T.XTestFakeButtonEvent(connection,1,down,0);X.XFlush(connection);time.sleep(.12)
     def angle():return int((run/'ticks').read_text().splitlines()[-1].split()[1])
     def firing():return int((run/'player').read_text().splitlines()[-1].split()[1])&1
     motion(x.value+w.value*65//100);button(1);assert firing(),('physical click did not fire',x.value,y.value,w.value,h.value,(run/'mouse').read_text() if (run/'mouse').exists() else 'no mouse reports',(run/'player').read_text().splitlines()[-3:])
     before=angle();motion(x.value+w.value+30);button(0);motion(x.value+w.value*35//100)
     delta=min((angle()-before)&0xffffffff,(before-angle())&0xffffffff)*360/2**32
     stuck=bool(firing()); print(f'{label}: physical outside release/return: firing={stuck}, turn={delta:.2f} degrees',flush=True)
     if label=='before':assert stuck or delta>5,'physical baseline did not reproduce'
     else:
      assert not stuck and delta<.1,'physical return still sticks or jumps'
      key=X.XKeysymToKeycode(connection,ord('m'))
      def toggle():
       T.XTestFakeKeyEvent(connection,key,1,0);X.XFlush(connection);time.sleep(.05)
       T.XTestFakeKeyEvent(connection,key,0,0);X.XFlush(connection);time.sleep(.05)
      toggle();before=angle();motion(x.value+w.value*45//100);assert angle()==before,'physical disabled mouse moves view'
      toggle();motion(x.value+w.value*50//100);assert angle()==before,'physical re-enable jumps view'
      motion(x.value+w.value*51//100);assert angle()!=before,'physical mouse never resumes'
      print('PASS physical m clutch pauses, re-anchors and resumes',flush=True)
    finally:
     ghost.terminate()
     try:ghost.wait(timeout=3)
     except S.TimeoutExpired:ghost.kill();ghost.wait()
 finally:
  if connection: X.XCloseDisplay(connection)
  xvfb.terminate();xvfb.wait(timeout=3);xvfb_log.close()
