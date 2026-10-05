/* slowtype FILE - write FILE to Output() a line at a time, Delay(1) between lines:
   every flush then scrolls a few lines by blit (never a full repaint) */
#include <proto/exec.h>
#include <proto/dos.h>
static char buf[32768];
int main(int argc, char **argv){
  BPTR fh, out = Output(); LONG n, i, s = 0;
  if (argc < 2 || !(fh = Open((STRPTR)argv[1], MODE_OLDFILE))) return 10;
  n = Read(fh, buf, sizeof buf); Close(fh);
  for (i = 0; i < n; i++) if (buf[i] == 10) { Write(out, buf + s, i + 1 - s); s = i + 1; Delay(1); }
  if (s < n) Write(out, buf + s, n - s);
  return 0; }
