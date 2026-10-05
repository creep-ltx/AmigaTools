/* btest BLOB: time engine.bin's frun (offset 0) on a fake console */
#include <proto/exec.h>
#include <proto/dos.h>
#include <proto/timer.h>
#include <devices/timer.h>
#include <stdio.h>
#include <string.h>
#include "/home/creep/Projects/AmigaTools/ccon/engine/con.h"
typedef unsigned long ULONG_;
struct fx { struct con **curcon; LONG *dfon,*dfpend,*dffull,*dflo,*dfhi,*dflost,*dfgen,*alteat,*dfnarrow,*maskon; UBYTE **dfd,**dfx0,**dfx1; LONG *dfo; UBYTE *dfdb,*dfx0b,*dfx1b; };
struct Device *TimerBase;
static ULONG now(void){ struct EClockVal e; ReadEClock(&e); return e.ev_lo; }
static struct con kk; static struct con *cur=&kk;
static LONG dfon=-1,dfpend=0,dffull=0,dflo=30,dfhi=-1,dflost=0,dfgen=1,alteat=0,dfnarrow=0,maskon=0,dfo=0;
static UBYTE db[512],x0b[512],x1b[512]; static UBYTE *d=db,*a=x0b,*b=x1b;
static UBYTE sb[77*200],sa[77*200],ss[77*200],sw[200],rp[100];
static UBYTE buf[10000];
typedef LONG (*frun_t)(struct fx *, const UBYTE *, LONG, LONG);
int main(int argc, char **argv){
  struct timerequest tr; struct con *k=&kk; int i; ULONG t; char o[100]; BPTR fh; LONG len; UBYTE *blob; frun_t fr;
  struct fx x={&cur,&dfon,&dfpend,&dffull,&dflo,&dfhi,&dflost,&dfgen,&alteat,&dfnarrow,&maskon,&d,&a,&b,&dfo,db,x0b,x1b};
  if(argc<2) return 10;
  fh=Open((STRPTR)argv[1],MODE_OLDFILE); if(!fh) return 10;
  blob=AllocVec(32768,MEMF_ANY); len=Read(fh,blob,32768); Close(fh); CacheClearU();
  fr=(frun_t)blob;
  if(OpenDevice((STRPTR)"timer.device",UNIT_ECLOCK,(struct IORequest*)&tr,0)) return 20;
  TimerBase=tr.tr_node.io_Device;
  k->rows=30;k->cols=77;k->sbmax=200;k->sb=(LONG)sb;k->sa=(LONG)sa;k->ss=(LONG)ss;k->sw=(LONG)sw;k->rp=(LONG)rp;
  k->jeff=7;k->jauto=-1;k->deffg=1;k->curfg=1;k->mfloor=1;k->mpens=1;
  memset(buf,10,10000);
  t=now(); fr(&x,buf,0,10000); t=now()-t; sprintf(o,"%-10s LF %lu us",argv[1],t*1000/709/10000); PutStr(o);
  for(i=0;i<10000;i++) buf[i]=(i%79==78)?10:33+i%90;
  dffull=0; t=now(); fr(&x,buf,0,10000); t=now()-t; sprintf(o,"  plain %lu ns/byte",t*100000/709/10000*10); PutStr(o);
  for(i=0;i<10000;i++){ buf[i]=33+i%90; }
  { int p=0; while(p<9900){ p+=sprintf((char*)buf+p,"\x1b[3%dm12345678",p%8); if(p%100<12) buf[p++]=10; } }
  { LONG rr; t=now(); rr=fr(&x,buf,0,9900); t=now()-t; sprintf(o,"  sgr %lu ns/byte (ret %ld, b %d %d %d)\n",t*100000/709/9900*10,rr,buf[0],buf[1],buf[2]); PutStr(o);}
  { int cfg; for(cfg=0;cfg<4;cfg++){ /* sync-line cadence: one 79-byte line, then a flush's bookkeeping */
    int ln; ULONG tt=0; for(i=0;i<79;i++) buf[i]=(i==78)?10:33+i%90;
    k->jeff=(cfg==0||cfg==3)?29:(cfg==1)?7:1; if(cfg==3) dffull=-1; k->jsync=(cfg==0)?5:0; k->jauto=(cfg==2)?0:-1; dffull=0; dfpend=0; k->cy=29; k->cx=0;
    for(ln=0;ln<200;ln++){ t=now(); fr(&x,buf,0,79); tt+=now()-t; dfpend=0; dffull=(cfg==3)?-1:0; dfgen++; if(dfgen>255){memset(db,0,512);dfgen=1;} dflo=30; dfhi=-1; dflost=0; }
    sprintf(o,"  syncline jeff %ld: %lu us/line\n",k->jeff,tt*1000/709/200); PutStr(o); } }
  { int ln, cfg; ULONG tt; static const char *nm[4]={"empty","1 char","1 LF","78 chars"};
    for(cfg=0;cfg<4;cfg++){ LONG L; tt=0; k->cy=10; k->cx=0;
      if(cfg==0) L=0; else if(cfg==1){buf[0]='A';L=1;} else if(cfg==2){buf[0]=10;L=1;} else {for(i=0;i<78;i++) buf[i]=33+i%90; L=78;}
      for(ln=0;ln<200;ln++){ if(cfg==1&&k->cx>70){k->cx=0;} t=now(); fr(&x,buf,0,L); tt+=now()-t; k->cx=0; if(k->cy>25)k->cy=10; dfpend=0; dffull=0; dfgen++; if(dfgen>255){memset(db,0,512);dfgen=1;} dflo=30; dfhi=-1; }
      sprintf(o,"  %-9s %lu us/call\n",nm[cfg],tt*1000/709/200); PutStr(o); } }
  FreeVec(blob); CloseDevice((struct IORequest*)&tr); return 0; }
