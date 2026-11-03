#ifndef COREX_APP_PROCESS_NATIVE_H
#define COREX_APP_PROCESS_NATIVE_H
#include <stdint.h>
/* Private, same-process ABI. id is an owned live/unreaped POSIX PID or Windows
 * process HANDLE encoded into u64 by an explicit Zig translation. Never use a
 * stale PID/handle. No pointers, allocation or resource ownership are exchanged.
 * exited: 1=exited (not reaped/closed), 0=running, -1=OS/argument error.
 * force_terminate: 0=termination requested, -1=OS/argument error. Caller must
 * subsequently reap/close the child. No process-tree termination is provided.
 */
#ifdef __cplusplus
extern "C" {
#endif
int32_t corex_process_exited(uint64_t id);
int32_t corex_process_force_terminate(uint64_t id);
#ifdef __cplusplus
}
#endif
#endif
