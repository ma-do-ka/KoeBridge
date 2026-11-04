#include "KoeBridgePOSIX.h"
#include <sys/file.h>

int KBFileLockTryExclusive(int fd) {
    return flock(fd, LOCK_EX | LOCK_NB);
}
