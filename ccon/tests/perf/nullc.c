/* nullc-handler - the null console: every packet answered at once, nothing
   drawn. conbench against it = the floor no console can go under (the
   client's own work, DOS, the packet round trip). Mount with
   Handler = ...nullc-handler, Priority = 5, GlobVec = -1. */
#include <exec/types.h>
#include <exec/execbase.h>
#include <dos/dosextens.h>
#include <dos/filehandler.h>
#include <proto/exec.h>
#include <proto/dos.h>
struct ExecBase *SysBase;
struct DosLibrary *DOSBase;
int start(void)
{
    struct Process *pr;
    struct MsgPort *port;
    struct Message *m;
    struct DosPacket *pk;
    struct DeviceNode *dn;
    SysBase = *(struct ExecBase **)4;
    pr = (struct Process *)FindTask(0);
    port = &pr->pr_MsgPort;
    WaitPort(port);
    m = GetMsg(port);
    pk = (struct DosPacket *)m->mn_Node.ln_Name;
    DOSBase = (struct DosLibrary *)OpenLibrary((CONST_STRPTR)"dos.library", 37);
    dn = (struct DeviceNode *)BADDR(pk->dp_Arg3);
    dn->dn_Task = port;
    ReplyPkt(pk, DOSTRUE, 0);
    for (;;) {
        WaitPort(port);
        while ((m = GetMsg(port))) {
            LONG r1 = DOSTRUE, r2 = 0;
            pk = (struct DosPacket *)m->mn_Node.ln_Name;
            switch (pk->dp_Type) {
            case ACTION_WRITE: r1 = pk->dp_Arg3; break;
            case ACTION_READ: r1 = 0; break;
            case ACTION_WAIT_CHAR: r1 = DOSFALSE; break;
            case ACTION_FINDINPUT: case ACTION_FINDOUTPUT: case ACTION_FINDUPDATE:
                ((struct FileHandle *)BADDR(pk->dp_Arg1))->fh_Arg1 = 1; break;
            case ACTION_END: case ACTION_SCREEN_MODE: break;
            case ACTION_IS_FILESYSTEM: r1 = DOSFALSE; break;
            default: r1 = DOSFALSE; r2 = ERROR_ACTION_NOT_KNOWN; break;
            }
            ReplyPkt(pk, r1, r2);
        }
    }
    return 0;
}
