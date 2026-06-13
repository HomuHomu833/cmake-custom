/* Android compat shim, force-included for the ninja build (see build.sh).
 *
 * ninja uses the posix_spawn family, which bionic only exports at API 28+ (we
 * target 25). bionic declares the posix_spawn*_t types but gates the functions,
 * so complete those opaque structs and implement the subset ninja needs via
 * fork/exec. Functions are static+unused -> emitted only where referenced. */
#ifndef CMAKE_ANDROID_COMPAT_H
#define CMAKE_ANDROID_COMPAT_H

#if defined(__ANDROID__) && (!defined(__ANDROID_API__) || __ANDROID_API__ < 28)

#include <spawn.h>      /* opaque posix_spawn*_t typedefs + POSIX_SPAWN_* flags */
#include <signal.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <sys/types.h>

#ifndef POSIX_SPAWN_SETPGROUP
#define POSIX_SPAWN_SETPGROUP 0x01
#endif
#ifndef POSIX_SPAWN_SETSIGMASK
#define POSIX_SPAWN_SETSIGMASK 0x08
#endif

struct __posix_spawnattr {
  short flags;
  pid_t pgroup;
  sigset_t sigmask;
};

enum { __FA_OPEN, __FA_CLOSE, __FA_DUP2 };
struct __fa_act {
  int type, fd, newfd, oflag;
  mode_t mode;
  char *path;
  struct __fa_act *next;
};
struct __posix_spawn_file_actions {
  struct __fa_act *head, *tail;
};

static inline __attribute__((__unused__))
int posix_spawnattr_init(posix_spawnattr_t *a) {
  struct __posix_spawnattr *p = (struct __posix_spawnattr *)calloc(1, sizeof(*p));
  if (!p) return ENOMEM;
  *a = p; return 0;
}
static inline __attribute__((__unused__))
int posix_spawnattr_destroy(posix_spawnattr_t *a) { free(*a); *a = 0; return 0; }
static inline __attribute__((__unused__))
int posix_spawnattr_setflags(posix_spawnattr_t *a, short f) { (*a)->flags = f; return 0; }
static inline __attribute__((__unused__))
int posix_spawnattr_setsigmask(posix_spawnattr_t *a, const sigset_t *m) { (*a)->sigmask = *m; return 0; }
static inline __attribute__((__unused__))
int posix_spawnattr_setpgroup(posix_spawnattr_t *a, pid_t pg) { (*a)->pgroup = pg; return 0; }

static inline __attribute__((__unused__))
int __cmake_fa_append(posix_spawn_file_actions_t *fa, struct __fa_act act) {
  struct __fa_act *n = (struct __fa_act *)malloc(sizeof(*n));
  if (!n) return ENOMEM;
  *n = act; n->next = 0;
  struct __posix_spawn_file_actions *p = *fa;
  if (p->tail) p->tail->next = n; else p->head = n;
  p->tail = n;
  return 0;
}
static inline __attribute__((__unused__))
int posix_spawn_file_actions_init(posix_spawn_file_actions_t *fa) {
  struct __posix_spawn_file_actions *p =
      (struct __posix_spawn_file_actions *)calloc(1, sizeof(*p));
  if (!p) return ENOMEM;
  *fa = p; return 0;
}
static inline __attribute__((__unused__))
int posix_spawn_file_actions_addopen(posix_spawn_file_actions_t *fa, int fd,
                                     const char *path, int oflag, mode_t mode) {
  struct __fa_act a; memset(&a, 0, sizeof a);
  a.type = __FA_OPEN; a.fd = fd; a.oflag = oflag; a.mode = mode;
  a.path = strdup(path);
  if (!a.path) return ENOMEM;
  return __cmake_fa_append(fa, a);
}
static inline __attribute__((__unused__))
int posix_spawn_file_actions_addclose(posix_spawn_file_actions_t *fa, int fd) {
  struct __fa_act a; memset(&a, 0, sizeof a);
  a.type = __FA_CLOSE; a.fd = fd;
  return __cmake_fa_append(fa, a);
}
static inline __attribute__((__unused__))
int posix_spawn_file_actions_adddup2(posix_spawn_file_actions_t *fa, int fd, int newfd) {
  struct __fa_act a; memset(&a, 0, sizeof a);
  a.type = __FA_DUP2; a.fd = fd; a.newfd = newfd;
  return __cmake_fa_append(fa, a);
}
static inline __attribute__((__unused__))
int posix_spawn_file_actions_destroy(posix_spawn_file_actions_t *fa) {
  struct __posix_spawn_file_actions *p = *fa;
  struct __fa_act *c = p ? p->head : 0;
  while (c) { struct __fa_act *n = c->next; free(c->path); free(c); c = n; }
  free(p); *fa = 0; return 0;
}

static inline __attribute__((__unused__))
int posix_spawn(pid_t *pid, const char *path,
                const posix_spawn_file_actions_t *fa,
                const posix_spawnattr_t *attr,
                char *const argv[], char *const envp[]) {
  pid_t c = fork();
  if (c < 0) return errno;
  if (c == 0) {
    if (attr && *attr) {
      struct __posix_spawnattr *ap = *attr;
      if (ap->flags & POSIX_SPAWN_SETPGROUP) setpgid(0, ap->pgroup);
      if (ap->flags & POSIX_SPAWN_SETSIGMASK) sigprocmask(SIG_SETMASK, &ap->sigmask, 0);
    }
    if (fa && *fa) {
      struct __fa_act *act = (*fa)->head;
      for (; act; act = act->next) {
        int r = 0;
        if (act->type == __FA_OPEN) {
          int f = open(act->path, act->oflag, act->mode);
          if (f < 0) _exit(127);
          if (f != act->fd) { r = dup2(f, act->fd); close(f); }
        } else if (act->type == __FA_CLOSE) {
          r = close(act->fd);
        } else { /* __FA_DUP2 */
          r = dup2(act->fd, act->newfd);
        }
        if (r < 0) _exit(127);
      }
    }
    execve(path, argv, envp);
    _exit(127);
  }
  if (pid) *pid = c;
  return 0;
}

#endif /* __ANDROID__ && API < 28 */
#endif /* CMAKE_ANDROID_COMPAT_H */
