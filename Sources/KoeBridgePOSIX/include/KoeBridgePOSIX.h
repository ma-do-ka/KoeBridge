#ifndef KOEBRIDGE_POSIX_H
#define KOEBRIDGE_POSIX_H

#ifdef __cplusplus
extern "C" {
#endif

/* Non-blocking exclusive lock on an already-open file descriptor.
   Returns 0 on success, -1 with errno on failure; closing fd releases lock.
   This C shim avoids the imported Darwin flock struct/function name collision. */
int KBFileLockTryExclusive(int fd);

#ifdef __cplusplus
}
#endif
#endif
