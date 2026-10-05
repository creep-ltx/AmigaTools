/* ptest2 BLOB...: time engine.bin's ppaint (offset 8, all=2) on a 77x28 page, 1 and 3 planes */
#include <proto/exec.h>
#include <proto/intuition.h>
#include <proto/graphics.h>
#include <proto/dos.h>
#include <proto/timer.h>
#include <devices/timer.h>
#include <graphics/gfx.h>
#include <stdio.h>
#include <string.h>
#include "/home/creep/Projects/AmigaTools/ccon/engine/con.h"
struct fx { struct con **curcon; LONG *dfon,*dfpend,*dffull,*dflo,*dfhi,*dflost,*dfgen,*alteat,*dfnarrow,*maskon; UBYTE **dfd,**dfx0,**dfx1; LONG *dfo; UBYTE *dfdb,*dfx0b,*dfx1b; };
struct pctx { const UBYTE *gl; LONG cs, ch, s, xb; UBYTE *pl[8]; LONG bpr, depth; UBYTE *sty; ULONG *tmp; };
struct Device *TimerBase;
static ULONG now(void){ struct EClockVal e; ReadEClock(&e); return e.ev_lo; }
static struct con kk; static struct con *cur=&kk;
static LONG dfon=-1,dfpend=0,dffull=0,dflo=0,dfhi=27,dflost=0,dfgen=1,alteat=0,dfnarrow=0,maskon=0,dfo=0;
static UBYTE db[512],x0b[512],x1b[512]; static UBYTE *d=db,*a=x0b,*b=x1b;
static UBYTE sb[77*28],sa[77*28],ss[77*28],sw[28];
static UBYTE gl[256*8]; static ULONG tmp[4096]; static UBYTE sty[64];
typedef LONG (*pp_t)(struct pctx *, struct fx *, LONG);
typedef void (*gs_t)(UBYTE *, const UBYTE *, LONG, LONG, LONG);
int main(int argc, char **argv){
  struct Screen *scr; struct Window *w; struct RastPort *rp; struct BitMap *bm; struct timerequest tr; struct TextFont *tf;
  struct con *k=&kk; static struct pctx pc; int i,r,arg; ULONG t; char o[120]; LONG ax,ay; UBYTE *gsh;
  struct fx x={&cur,&dfon,&dfpend,&dffull,&dflo,&dfhi,&dflost,&dfgen,&alteat,&dfnarrow,&maskon,&d,&a,&b,&dfo,db,x0b,x1b};
  if(OpenDevice((STRPTR)"timer.device",UNIT_ECLOCK,(struct IORequest*)&tr,0)) return 20;
  TimerBase=tr.tr_node.io_Device;
  scr=LockPubScreen(0);
  w=OpenWindowTags(0,WA_Left,0,WA_Top,0,WA_Width,640,WA_Height,256,WA_PubScreen,(ULONG)scr,WA_Title,(ULONG)"ptest2",WA_DragBar,TRUE,WA_SizeGadget,TRUE,WA_DepthGadget,TRUE,TAG_DONE);
  UnlockPubScreen(0,scr); if(!w) return 20;
  rp=w->RPort; bm=rp->BitMap; tf=rp->Font;
  for(i=0;i<256;i++){ int ci=(i>=tf->tf_LoChar&&i<=tf->tf_HiChar)?i-tf->tf_LoChar:tf->tf_HiChar-tf->tf_LoChar+1; ULONG loc=((ULONG*)tf->tf_CharLoc)[ci]; int off=loc>>16,y; for(y=0;y<8;y++){ UBYTE*dd=(UBYTE*)tf->tf_CharData+y*tf->tf_Modulo; ULONG wv=(dd[off>>3]<<8)|dd[(off>>3)+1]; gl[i*8+y]=(wv<<(off&7))>>8; } }
  ax=w->LeftEdge+w->BorderLeft; ay=w->TopEdge+w->BorderTop;
  k->cols=77; k->rows=28; k->sbmax=28; k->sb=(LONG)sb; k->sa=(LONG)sa; k->ss=(LONG)ss; k->sw=(LONG)sw; k->deffg=1;
  for(r=0;r<28;r++) for(i=0;i<77;i++){ sb[r*77+i]=33+(r*7+i)%90; sa[r*77+i]=(r&1)?1:(1+(i/8)%7); }
  gsh=AllocVec(256*16,MEMF_ANY);
  for(arg=1;arg<argc;arg++){
    BPTR fh=Open((STRPTR)argv[arg],MODE_OLDFILE); UBYTE *blob; pp_t pp; gs_t gs;
    if(!fh) continue; blob=AllocVec(32768,MEMF_ANY); Read(fh,blob,32768); Close(fh); CacheClearU();
    gs=(gs_t)(blob+12); pp=(pp_t)(blob+8);
    gs(gsh,gl,8,8,ax&7);
    pc.gl=gsh; pc.cs=8; pc.ch=8; pc.s=ax&7; pc.xb=ax>>3; for(i=0;i<bm->Depth;i++) pc.pl[i]=bm->Planes[i]+ay*bm->BytesPerRow; pc.bpr=bm->BytesPerRow; pc.depth=bm->Depth; pc.sty=sty; pc.tmp=tmp;
    for(r=0;r<28;r++) for(i=0;i<77;i++) sa[r*77+i]=1;
    k->mmask=1; t=now(); for(i=0;i<5;i++) pp(&pc,&x,2); t=now()-t; sprintf(o,"%-14s plain 1pl %5lu",argv[arg],t*1000/709/(5*28)); PutStr(o);
    for(r=0;r<28;r++) for(i=0;i<77;i++) sa[r*77+i]=(r&1)?1:(1+(i/8)%7);
    k->mmask=1; t=now(); for(i=0;i<5;i++) pp(&pc,&x,2); t=now()-t; sprintf(o,"  mixed 1pl %5lu",t*1000/709/(5*28)); PutStr(o);
    k->mmask=7; t=now(); for(i=0;i<5;i++) pp(&pc,&x,2); t=now()-t; sprintf(o,"  3pl %5lu us/row\n",t*1000/709/(5*28)); PutStr(o);
    FreeVec(blob);
  }
  Delay(25); CloseWindow(w); CloseDevice((struct IORequest*)&tr); return 0; }
