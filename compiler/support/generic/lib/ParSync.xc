// ParSync.xc — what the standard library's writers call before handing a
// buffer to the system (#15). A GPU run may leave an output on its device,
// the array's pages no-access until the host touches them (ParDevice, the
// resident blocks); a touch from the program's own code faults and fetches
// it, but a system call given the array (write(), send()) does not fault:
// it fails with EFAULT. So Files, Socket and Http call parSync on what they
// are given first. It does nothing until the par runtime puts its syncer
// here, which it does when it first keeps an array on a device; a program
// that never does pays one test.
//
// This file stands alone (no par runtime), so the writers can import it.
class ParSyncer
    {
    void sync(pointer p, u64 n)
        {
        }
    }

Object* gParSyncer;

// Bring every array overlapping [p, p + n) that a device keeps back to the host.
void parSync(pointer p, u64 n)
    {
    if (gParSyncer != (Object*)0 && p != (pointer)0 && n > (u64)0)
        ((ParSyncer*)gParSyncer).sync(p, n);
    }
