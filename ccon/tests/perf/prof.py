#!/usr/bin/env python3
# prof.py IN OUT - inject EClock phase counters (port CCON.prof) into a ccon-handler.e copy
import re,sys
s=open(sys.argv[1],encoding='latin1').read()
def rep(a,b):
    global s
    assert s.count(a)==1,(a,s.count(a)); s=s.replace(a,b)
rep("'cybergraphics', 'graphics/clip', 'timer',","'cybergraphics', 'graphics/clip', 'timer', 'exec/memory', 'exec/lists',")
rep("DEF p96base=NIL,","DEF prof=NIL:PTR TO LONG, profport=NIL:PTR TO mp, p96base=NIL,")
rep("  DEF msigs, proc:PTR TO process,","  DEF ptb, pti, msigs, proc:PTR TO process,")
m=re.search(r"\n  IF treq THEN timerbase := treq.io.device[^\n]*\n",s)
s=s[:m.end()]+"""  IF treq
    profport := AllocMem(SIZEOF mp + 4 + 256, MEMF_PUBLIC OR MEMF_CLEAR)
    IF profport
      profport.ln.type := NT_MSGPORT
      profport.ln.name := 'CCON.prof'
      profport.flags := PA_IGNORE
      newlist(profport.msglist)
      prof := profport + SIZEOF mp + 2
      prof := And(prof + 3, $FFFFFFFC)
      AddPort(profport)
    ENDIF
  ENDIF
"""+s[m.end():]
rep("  WHILE dieing = FALSE\n","  ptb := pnow()\n  WHILE dieing = FALSE\n")
rep("    msigs := Wait(psig OR wsig)\n","    pacc(0, ptb)\n    pti := pnow()\n    msigs := Wait(psig OR wsig)\n    pacc(1, pti)\n    ptb := pnow()\n")
wraps=[('dopkt',2),('flushout',3),('render',4),('dfflush',5),('dfspans',7),('frun',8),('dfstart',9),('dorender',10),('dpaint',11),('ppsetup',12),('drawmodelcells',13),('drawmrow',6),('fcall3',14),('dpplanar',15)]
for name,i in wraps:
    m=re.search(r"\nPROC "+name+r"\(([^)]*)\)",s)
    assert m,name
    args=m.group(1)
    names=[a.split(':')[0].strip() for a in args.split(',') if a.strip()]
    # rename original
    s=s[:m.start()]+"\nPROC "+name+"0("+args+")"+s[m.end():]
    w="\nPROC %s(%s)\n  DEF pt_, pr_\n  pt_ := pnow()\n  pr_ := %s0(%s)\n  pacc(%d, pt_)\nENDPROC pr_\n"%(name,args,name,", ".join(names),i)
    s=s.rstrip('\n')+"\n"+w
s+="""
PROC newlist(l:PTR TO lh)
  l.head := l + 4
  l.tail := NIL
  l.tailpred := l
ENDPROC

PROC pnow()
  DEF ev:eclockval
  IF timerbase = NIL THEN RETURN 0
  ReadEClock(ev)
ENDPROC ev.lo

PROC pacc(i, t0)
  DEF t
  IF prof = NIL THEN RETURN
  t := pnow()
  prof[Shl(i, 1)] := prof[Shl(i, 1)] + (t - t0)
  prof[Shl(i, 1) + 1] := prof[Shl(i, 1) + 1] + 1
ENDPROC
"""
open(sys.argv[2],'w',encoding='latin1').write(s)
