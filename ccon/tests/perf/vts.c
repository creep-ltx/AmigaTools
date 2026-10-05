/* vts BLOB N: N sgr-colour lines (8 x ESC[3km12345678 + LF), frun + cflush each, 3 planes */
#include <proto/exec.h>
#include <proto/dos.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "/home/creep/Projects/AmigaTools/ccon/engine/con.h"
struct fx { struct con **curcon; LONG *dfon,*dfpend,*dffull,*dflo,*dfhi,*dflost,*dfgen,*alteat,*dfnarrow,*maskon; UBYTE **dfd,**dfx0,**dfx1; LONG *dfo; UBYTE *dfdb,*dfx0b,*dfx1b; LONG *conlist,*flusharmed,*port; void *sysbase; LONG *dfvb; void *gfxbase; };
struct pctx { const UBYTE *gl; LONG cs, ch, s, xb; UBYTE *pl[8]; LONG bpr, depth; UBYTE *sty; ULONG *tmp; };
static struct con kk; static struct con *cur=&kk;
static LONG dfon=-1,dfpend=0,dffull=0,dflo=30,dfhi=-1,dflost=0,dfgen=1,alteat=0,dfnarrow=0,maskon=-1,dfo=0,dfvb=0;
static UBYTE db[512],x0b[512],x1b[512]; static UBYTE *d=db,*a=x0b,*b=x1b;
static UBYTE sb[77*60],sa[77*60],ss[77*60],sw[60];
static UBYTE gsh[256*16]; static ULONG tmp[4096]; static UBYTE sty[64]; static UBYTE planes[320*256];
static UWORD fakelib[300]; static UBYTE rp[100], layer[100], cr[40], win[200]; static UBYTE buf[200]; static int blen;
typedef LONG (*f2_t)(void *, void *); typedef LONG (*fr_t)(struct fx *, const UBYTE *, LONG, LONG);
int main(int argc, char **argv){
  struct con *k=&kk; static struct pctx pc; int i,n; char o[100]; BPTR fh; UBYTE *blob; fr_t fr; f2_t cf;
  struct fx x={&cur,&dfon,&dfpend,&dffull,&dflo,&dfhi,&dflost,&dfgen,&alteat,&dfnarrow,&maskon,&d,&a,&b,&dfo,db,x0b,x1b,0,0,0,0,&dfvb,0};
  { UBYTE *fb=(UBYTE*)fakelib+560; int o2; for(o2=6;o2<=540;o2+=6) *(UWORD*)(fb-o2)=0x4E75; x.gfxbase=fb; }
  fh=Open((STRPTR)argv[1],MODE_OLDFILE); blob=AllocVec(32768,MEMF_ANY); Read(fh,blob,32768); Close(fh);
  fr=(fr_t)blob; cf=(f2_t)(blob+20); n=atoi(argv[2]);
  *(UBYTE**)rp=layer; *(UBYTE**)(layer+8)=cr; *(WORD*)(win+8)=640; *(WORD*)(win+10)=256; win[54]=4; win[55]=11; win[56]=18; win[57]=2;
  k->rows=30;k->cols=77;k->sbmax=60;k->sb=(LONG)sb;k->sa=(LONG)sa;k->ss=(LONG)ss;k->sw=(LONG)sw;k->rp=(LONG)rp;k->win=(LONG)win;
  k->jeff=29;k->jauto=-1;k->jsync=5;k->deffg=1;k->curfg=1;k->mfloor=1;k->mpens=1;k->mmask=7;k->mpens=7;k->cy=29;k->ch=8;
  pc.gl=gsh; pc.cs=8; pc.ch=8; pc.s=4; pc.xb=0; for(i=0;i<4;i++) pc.pl[i]=planes+80*i+12*320; pc.bpr=320; pc.depth=4; pc.sty=sty; pc.tmp=tmp;
  { int q; blen=0; for(q=0;q<8;q++){ buf[blen++]=27; buf[blen++]=0x5b; buf[blen++]=0x33; buf[blen++]=0x30+q; buf[blen++]=0x6d; memcpy(buf+blen,"12345678",8); blen+=8; } buf[blen++]=10; }
  fr(&x,buf,0,blen); cf(&x,&pc);    /* warm: the pens tables */
  sprintf(o,"BLOB %lx\n",(ULONG)blob); PutStr(o);
  for(i=0;i<n;i++){ fr(&x,buf,0,blen); cf(&x,&pc); }
  PutStr("DONE\n"); return 0; }
