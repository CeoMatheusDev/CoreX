/* Platform extensions only; never window/input. Fixed-width C ABI, no ownership
 * transfer. Poll observes exit WITHOUT reaping/closing the process; only the
 * supervisor can reap, preventing PID reuse while timeout cleanup is pending. */
#define _POSIX_C_SOURCE 200809L
#include "process_native.h"
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

int32_t corex_process_exited(uint64_t id) {
    DWORD result = WaitForSingleObject((HANDLE)(uintptr_t)id, 0);
    if (result == WAIT_OBJECT_0) return 1;
    if (result == WAIT_TIMEOUT) return 0;
    return -1;
}
int32_t corex_process_force_terminate(uint64_t id) {
    return TerminateProcess((HANDLE)(uintptr_t)id, 1) ? 0 : -1;
}
#else
#include <errno.h>
#include <signal.h>
#include <sys/types.h>
#include <sys/wait.h>

int32_t corex_process_exited(uint64_t id) {
    if (id == 0 || id > INT32_MAX) return -1;
    siginfo_t info = {0};
    int result;
    do {
        result = waitid(P_PID, (id_t)id, &info, WEXITED | WNOHANG | WNOWAIT);
    } while (result < 0 && errno == EINTR);
    if (result < 0) return -1;
    return info.si_pid != 0 ? 1 : 0;
}
int32_t corex_process_force_terminate(uint64_t id) {
    if (id == 0 || id > INT32_MAX) return -1;
    int result;
    do { result = kill((pid_t)id, SIGKILL); } while (result < 0 && errno == EINTR);
    return result == 0 ? 0 : -1;
}
#endif
