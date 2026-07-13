/*
 * netbsd_mips_compat.c — supply the version-renamed libc symbols that zig's
 * NetBSD abilist tags for the other arches but omits for mips.
 *
 * NetBSD's headers __RENAME() kevent() -> __kevent100 and dup3() -> __dup3100
 * (see sys/event.h, unistd.h). zig's bundled NetBSD abilist provides those
 * symbols for aarch64/x86_64/etc. but not for mips, so cmlibuv's kqueue backend
 * fails to link on mips-NetBSD with "undefined symbol: __kevent100 / __dup3100".
 * These definitions match zig's bundled NetBSD 10 ABI, so they are safe to link
 * only for that gap. Compiled and appended to the exe link by scripts/build.sh.
 */
#include <sys/types.h>
#include <sys/syscall.h>
#include <sys/event.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>

/* NetBSD has no dup3 syscall (no SYS_dup3); libc composes it from dup2 +
 * FD_CLOEXEC. Mirror that: dup3(2) errors on equal fds (unlike dup2) and only
 * O_CLOEXEC is a documented flag. The dup2/fcntl pair is non-atomic, but that is
 * exactly cmlibuv's own fallback on platforms lacking dup3. */
int __dup3100(int oldd, int newd, int flags) {
	if (oldd == newd) {
		errno = EINVAL;
		return -1;
	}
	if (dup2(oldd, newd) == -1)
		return -1;
	if ((flags & O_CLOEXEC) && fcntl(newd, F_SETFD, FD_CLOEXEC) == -1) {
		int saved = errno;
		(void)close(newd);
		errno = saved;
		return -1;
	}
	return newd;
}

/* kevent(2): NetBSD 10 syscall 501 (SYS___kevent100). NetBSD syscall numbers are
 * architecture-independent, and struct kevent here is the same definition
 * cmlibuv compiled against, so this is ABI-correct for mips. */
int __kevent100(int kq, const struct kevent *changelist, size_t nchanges,
                struct kevent *eventlist, size_t nevents,
                const struct timespec *timeout) {
	return syscall(SYS___kevent100, kq, changelist, nchanges,
	               eventlist, nevents, timeout);
}
