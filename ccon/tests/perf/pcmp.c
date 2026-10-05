/* pcmp OLDBLOB NEWBLOB [trials] - paint random rows with both engines' ppaint into
   memory bitplanes and compare every byte (and the styled answer) */
#include <proto/exec.h>
#include <proto/dos.h>
#include <exec/memory.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "/home/creep/Projects/AmigaTools/ccon/engine/con.h"
struct fx { struct con **curcon; LONG *dfon,*dfpend,*dffull,*dflo,*dfhi,*dflost,*dfgen,*alteat,*dfnarrow,*maskon; UBYTE **dfd,**dfx0,**dfx1; LONG *dfo; UBYTE *dfdb,*dfx0b,*dfx1b; };
struct pctx { const UBYTE *gl; LONG cs, ch, s, xb; UBYTE *pl[8]; LONG bpr, depth; UBYTE *sty; ULONG *tmp; };
typedef LONG (*pp_t)(struct pctx *, struct fx *, LONG);
typedef void (*gs_t)(UBYTE *, const UBYTE *, LONG, LONG, LONG);
static ULONG seed=1; static ULONG rnd(ULONG n){ seed=seed*1103515245+12345; return (seed>>16)%n; }
static UBYTE *load(const char *n){ BPTR fh=Open((STRPTR)n,MODE_OLDFILE); UBYTE *b; if(!fh) return 0; b=AllocVec(32768,MEMF_ANY|MEMF_CLEAR); Read(fh,b,32768); Close(fh); CacheClearU(); return b; }
#define MAXR 12
#define MAXC 120
static struct con kk; static struct con *cur=&kk;
static LONG dfon=-1,dfpend=0,dffull=0,dflo,dfhi,dflost=0,dfgen=1,alteat=0,dfnarrow=0,maskon=0,dfo=0;
static UBYTE db[512],x0b[512],x1b[512]; static UBYTE *d=db,*a=x0b,*b=x1b;
static UBYTE sb[MAXR*MAXC+16],sa[MAXR*MAXC+16],ss[MAXR*MAXC+16],sw[64];
static UBYTE font[256*8], sty1[64], sty2[64];
static void scrub(int v){ volatile UBYTE buf[6000]; int i; for(i=0;i<6000;i++) buf[i]=v; }
int main(int argc,char **argv){
  UBYTE *o=load(argv[1]), *nw=load(argv[2]); pp_t po,pn; gs_t gs;
  int trials=argc>3?atoi(argv[3]):2000, t, i, r, p, bad=0, bpr, depth, rows, cols, psz;
  UBYTE *g1=AllocVec(256*16,MEMF_ANY), *pa=AllocVec(8*144*8*MAXR,MEMF_ANY), *pb=AllocVec(8*144*8*MAXR,MEMF_ANY);
  ULONG *t1=AllocVec(16384,MEMF_ANY|MEMF_CLEAR), *t2=AllocVec(16384,MEMF_ANY|MEMF_CLEAR);
  struct fx x={&cur,&dfon,&dfpend,&dffull,&dflo,&dfhi,&dflost,&dfgen,&alteat,&dfnarrow,&maskon,&d,&a,&b,&dfo,db,x0b,x1b};
  static struct pctx c1, c2; char ob[200];
  if(!o||!nw) return 20;
  po=(pp_t)(o+8); pn=(pp_t)(nw+8); gs=(gs_t)(o+12);
  for(i=0;i<256*8;i++) font[i]=rnd(256);
  for(t=0;t<trials;t++){
    LONG s=rnd(8), xb=rnd(5), ra, rn, all=rnd(4)==0, pal=rnd(4);
    rows=1+rnd(MAXR); cols=1+rnd(MAXC-8); depth=1+rnd(5);
    bpr=((xb+cols+2+3)/4)*4+4*rnd(3);
    psz=bpr*8*rows;
    gs(g1,font,8,8,s);
    struct con *k=&kk; memset(k,0,sizeof(*k));
    k->cols=cols; k->rows=rows; k->sbmax=rows; k->sbtop=0; k->sb=(LONG)sb; k->sa=(LONG)sa; k->ss=(LONG)ss; k->sw=(LONG)sw;
    k->deffg=1+rnd(7); k->mmask=1+rnd((1<<depth)-1);
    for(i=0;i<rows*cols+16;i++){
      sb[i]=rnd(256);
      if(pal==0) sa[i]=1; else if(pal==1) sa[i]=1+((i/8)%7); else if(pal==2) sa[i]=rnd(256); else sa[i]=(rnd(6)==0)?rnd(256):k->deffg;
      ss[i]=rnd(5)==0?(rnd(2)?4:rnd(16)):0;
    }
    for(i=0;i<psz*depth;i++) pa[i]=pb[i]=rnd(256);
    if(argc>5) for(i=0;i<psz*depth;i++) pa[i]=pb[i]=0x55;
    for(r=0;r<512;r++) db[r]=0;
    dflo=rows; dfhi=-1;
    for(r=0;r<rows;r++) if(rnd(3)){ int u=rnd(cols), v=rnd(cols); if(u>v){int w=u;u=v;v=w;} db[r]=1; x0b[r]=u; x1b[r]=v; if(r<dflo)dflo=r; if(r>dfhi)dfhi=r; }
    c1.gl=g1; c1.cs=8; c1.ch=8; c1.s=s; c1.xb=xb; c1.bpr=bpr; c1.depth=depth; c1.sty=sty1; c1.tmp=t1;
    for(p=0;p<depth;p++) c1.pl[p]=pa+p*psz;
    c2=c1; c2.sty=sty2; c2.tmp=t2; for(p=0;p<depth;p++) c2.pl[p]=pb+p*psz;
    if(argc>4 && t==atoi(argv[4])){ sprintf(ob,"row0 dirty %d span %d..%d; init plane0 line0:",db[0],x0b[0],x1b[0]); PutStr(ob); for(i=0;i<20;i++){ sprintf(ob," %02x",pa[i]); PutStr(ob);} PutStr("\n"); }
    ra=po(&c1,&x,all?2:0);
    if(getenv("SCRUB")) scrub(atoi(getenv("SCRUB")));
    rn=pn(&c2,&x,all?2:0);
    if(argc>4 && t==atoi(argv[4])){ PutStr("old plane0 line0:"); for(i=0;i<20;i++){ sprintf(ob," %02x",pa[i]); PutStr(ob);} PutStr("\nnew plane0 line0:"); for(i=0;i<20;i++){ sprintf(ob," %02x",pb[i]); PutStr(ob);} PutStr("\n"); }
    if(argc>4 && t==atoi(argv[4])){ ULONG *e=(ULONG*)((UBYTE*)t2+4096); int q;
      sprintf(ob,"bpr %d q?  s %ld xb %ld cols %d\n",bpr,(long)s,(long)xb,cols); PutStr(ob);
      for(q=0;q<12;q++){ if(e[1]==0) break; sprintf(ob,"entry ch=%lx(+%ld) ng=%lu e=%08lx :",(unsigned long)e[0],(long)((UBYTE*)e[0]-(UBYTE*)t2),(unsigned long)e[1],(unsigned long)e[2]); PutStr(ob);
        { ULONG *pp=e+3; while(*pp){ sprintf(ob," [dst+%ld A=%08lx X=%08lx]",(long)((UBYTE*)pp[0]-pb),(unsigned long)pp[1],(unsigned long)pp[2]); PutStr(ob); pp+=3; } PutStr("\n"); e=pp+1; } }
      for(p=0;p<depth;p++){ sprintf(ob,"plane %d old:",p); PutStr(ob); for(i=0;i<8;i++){ sprintf(ob," %02x",pa[p*psz+i]); PutStr(ob);} PutStr("  new:"); for(i=0;i<8;i++){ sprintf(ob," %02x",pb[p*psz+i]); PutStr(ob);} PutStr("\n"); } }
    if(ra!=rn){ sprintf(ob,"trial %d: styled %ld vs %ld\n",t,(long)ra,(long)rn); PutStr(ob); bad++; }
    for(r=0;r<rows;r++) if(sty1[r]!=sty2[r]){ sprintf(ob,"trial %d: sty row %d %d vs %d\n",t,r,sty1[r],sty2[r]); PutStr(ob); bad++; break; }
    for(i=0;i<psz*depth;i++) if(pa[i]!=pb[i]){
      sprintf(ob,"trial %d: plane byte %d (plane %d line %d byte %d) %02x vs %02x  cols %d rows %d depth %d s %ld xb %ld mask %ld all %ld pal %ld\n",t,i,i/psz,(i%psz)/bpr,(i%psz)%bpr,pa[i],pb[i],cols,rows,depth,(long)s,(long)xb,(long)k->mmask,(long)all,(long)pal); PutStr(ob); bad++; break; }
    if(bad>5) break;
  }
  sprintf(ob,"%d trials, %d bad\n",t,bad); PutStr(ob); return bad?10:0; }
