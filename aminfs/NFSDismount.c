/*
 * NFSDismount - cleanly stop an AmiNFS handler.
 *
 * Sends ACTION_DIE to the named device's handler. The handler refuses
 * while any lock or file on it is open (ERROR_OBJECT_IN_USE); on
 * success it removes its volume from the DOS list, clears dn_Task and
 * exits, so the next reference to the device mounts it afresh.
 *
 * Usage: NFSDismount DEVICE/A     (e.g. NFSDismount NFS0:)
 */

#include <exec/types.h>
#include <dos/dos.h>
#include <dos/dosextens.h>
#include <proto/exec.h>
#include <proto/dos.h>
#include <string.h>

static const char verstag[] __attribute__((used)) =
    "$VER: NFSDismount 0.1 (14.8.2026)";

int main(void)
{
    STRPTR args[1] = { NULL };
    struct RDArgs *rd;
    char name[64];
    struct DosList *dl;
    struct MsgPort *task = NULL;
    LONG i, res;

    rd = ReadArgs("DEVICE/A", (LONG *)args, NULL);
    if (!rd) {
        PrintFault(IoErr(), "NFSDismount");
        return RETURN_ERROR;
    }
    for (i = 0; args[0][i] && args[0][i] != ':' && i < 63; i++)
        name[i] = args[0][i];
    name[i] = 0;

    dl = LockDosList(LDF_DEVICES | LDF_READ);
    dl = FindDosEntry(dl, name, LDF_DEVICES);
    if (dl) task = dl->dol_Task;
    /* Unlock BEFORE talking to the handler: its DIE teardown takes the
     * dos list write lock to remove the volume - holding read here
     * would deadlock the pair of us. */
    UnLockDosList(LDF_DEVICES | LDF_READ);

    if (!dl) {
        Printf("NFSDismount: no such device \"%s:\"\n", name);
        FreeArgs(rd);
        return RETURN_ERROR;
    }
    if (!task) {
        Printf("%s: not mounted (no handler running)\n", name);
        FreeArgs(rd);
        return RETURN_WARN;
    }

    res = DoPkt(task, ACTION_DIE, 0, 0, 0, 0, 0);
    if (res) {
        Printf("%s: dismounted\n", name);
        FreeArgs(rd);
        return RETURN_OK;
    }
    if (IoErr() == ERROR_OBJECT_IN_USE)
        Printf("%s: in use - close its files and windows first\n", name);
    else
        PrintFault(IoErr(), name);
    FreeArgs(rd);
    return RETURN_ERROR;
}
