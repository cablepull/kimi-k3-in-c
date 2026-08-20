/* k3_portable_io.h - shims for the Linux-only I/O calls the readers use.
 *
 * The engine asks for two things Linux gives it and Darwin does not spell the same way:
 *
 *   O_DIRECT       bypass the page cache on the trunk and expert reads. Darwin's
 *                  equivalent is not an open() flag but fcntl(F_NOCACHE) after the
 *                  fact, so O_DIRECT is defined to 0 here (open() is unaffected) and
 *                  k3_set_direct() applies the real thing to the returned descriptor.
 *
 *   posix_fadvise  a page-cache prefetch hint with no Darwin equivalent. Callers
 *                  already treat it as advisory -- the one call site returns early on
 *                  the direct path because the hint has nothing to populate there -- so
 *                  the shim is a no-op that keeps the buffered path compiling.
 *
 * Both call sites fall back to buffered reads when the direct path is unavailable, so
 * neither shim changes what the engine computes, only how fast it reads.
 */
#ifndef K3_PORTABLE_IO_H
#define K3_PORTABLE_IO_H

/* The readers define _POSIX_C_SOURCE, which hides Darwin's non-standard fcntl commands
 * (F_NOCACHE among them) from <fcntl.h>. _DARWIN_C_SOURCE puts them back. It must be
 * set before the first libc header is pulled in, so this header is included first. */
#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE
#endif

#include <fcntl.h>

#if defined(__APPLE__)

/* Not an open() flag on Darwin: defining it to 0 leaves open() semantics untouched. */
#ifndef O_DIRECT
#define O_DIRECT 0
#endif

#ifndef POSIX_FADV_WILLNEED
#define POSIX_FADV_WILLNEED 3
#endif

static inline int posix_fadvise(int fd, off_t off, off_t len, int advice)
{
    (void)fd; (void)off; (void)len; (void)advice;
    return 0;   /* advisory only; the buffered path is correct without it */
}

/* Darwin's O_DIRECT equivalent, applied after open(). Failure is not fatal: the caller
 * keeps the descriptor and reads through the page cache instead. K3_BUFFERED=1 skips
 * the fcntl entirely: on a machine whose RAM exceeds the working set, letting the page
 * cache absorb trunk and expert reads can beat uncached I/O, and the env var makes that
 * an A/B on one binary rather than a comparison of two builds. */
#include <stdlib.h>
static inline int k3_set_direct(int fd)
{
    if (fd < 0) return -1;
    if (getenv("K3_BUFFERED")) return 0;
    return fcntl(fd, F_NOCACHE, 1);
}

#else   /* Linux and friends: O_DIRECT on open() already did it */

static inline int k3_set_direct(int fd) { (void)fd; return 0; }

#endif

/* Largest request a single pread() may carry. Linux silently truncates bigger requests
 * to 0x7ffff000 bytes and returns short, which the retry loops absorb; Darwin instead
 * REJECTS anything over INT_MAX with EINVAL, and a -1 is indistinguishable from a real
 * error inside those loops. One clamp below the smaller of the two limits serves both.
 * Only the embedding table (2.35 GB at the released shape) ever exceeds it. */
#define K3_PREAD_MAX ((int64_t)1 << 30)

#endif /* K3_PORTABLE_IO_H */
