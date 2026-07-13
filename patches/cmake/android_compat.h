/* Android compat shim, force-included for the ninja build (see build.sh).
 *
 * ninja uses the posix_spawn family, which bionic only exports at API 28+ (we
 * target 25). bionic declares the posix_spawn*_t types but gates the functions,
 * so complete those opaque structs and implement the subset ninja needs via
 * fork/exec, with a CLOEXEC self-pipe so exec/setup errno reaches the parent
 * (real POSIX semantics, not a stub). Statics -> emitted only where used. */
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
#include <sys/wait.h>

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

/* Report a setup/exec failure from the child to the parent: write errno down
 * the CLOEXEC self-pipe, then _exit. The pipe closes on a successful execve,
 * so a zero-length read in the parent means "exec succeeded". */
static inline __attribute__((__unused__))
void __cmake_spawn_fail(int wfd) {
  int e = errno;
  while (write(wfd, &e, sizeof e) < 0 && errno == EINTR) {}
  _exit(127);
}

static inline __attribute__((__unused__))
int posix_spawn(pid_t *pid, const char *path,
                const posix_spawn_file_actions_t *fa,
                const posix_spawnattr_t *attr,
                char *const argv[], char *const envp[]) {
  int err_pipe[2];
  if (pipe(err_pipe) < 0) return errno;
  /* CLOEXEC so a successful execve auto-closes the write end (EOF for parent),
   * and the descriptors never leak into the spawned program. */
  fcntl(err_pipe[0], F_SETFD, FD_CLOEXEC);
  fcntl(err_pipe[1], F_SETFD, FD_CLOEXEC);

  pid_t c = fork();
  if (c < 0) {
    int e = errno;
    close(err_pipe[0]); close(err_pipe[1]);
    return e;
  }
  if (c == 0) {
    close(err_pipe[0]);
    if (attr && *attr) {
      struct __posix_spawnattr *ap = *attr;
      if ((ap->flags & POSIX_SPAWN_SETPGROUP) && setpgid(0, ap->pgroup) < 0)
        __cmake_spawn_fail(err_pipe[1]);
      if ((ap->flags & POSIX_SPAWN_SETSIGMASK) &&
          sigprocmask(SIG_SETMASK, &ap->sigmask, 0) < 0)
        __cmake_spawn_fail(err_pipe[1]);
    }
    if (fa && *fa) {
      struct __fa_act *act = (*fa)->head;
      for (; act; act = act->next) {
        if (act->type == __FA_OPEN) {
          int f = open(act->path, act->oflag, act->mode);
          if (f < 0) __cmake_spawn_fail(err_pipe[1]);
          if (f != act->fd) {
            if (dup2(f, act->fd) < 0) { close(f); __cmake_spawn_fail(err_pipe[1]); }
            close(f);
          }
        } else if (act->type == __FA_CLOSE) {
          if (close(act->fd) < 0) __cmake_spawn_fail(err_pipe[1]);
        } else { /* __FA_DUP2 */
          if (dup2(act->fd, act->newfd) < 0) __cmake_spawn_fail(err_pipe[1]);
        }
      }
    }
    execve(path, argv, envp);
    __cmake_spawn_fail(err_pipe[1]);
  }

  close(err_pipe[1]);
  /* Read the child's errno, if any. EOF (n == 0) => execve succeeded. */
  int child_err = 0, n;
  while ((n = read(err_pipe[0], &child_err, sizeof child_err)) < 0 && errno == EINTR) {}
  close(err_pipe[0]);
  if (n > 0) {
    int st;
    while (waitpid(c, &st, 0) < 0 && errno == EINTR) {}  /* reap; don't leak a zombie */
    return child_err;
  }
  if (pid) *pid = c;
  return 0;
}

static inline __attribute__((__unused__))
int posix_spawnp(pid_t *pid, const char *file,
                 const posix_spawn_file_actions_t *fa,
                 const posix_spawnattr_t *attr,
                 char *const argv[], char *const envp[]) {
  if (strchr(file, '/'))
    return posix_spawn(pid, file, fa, attr, argv, envp);
  const char *path = getenv("PATH");
  if (!path) path = "/system/bin:/vendor/bin:/bin:/usr/bin";
  char *path_copy = strdup(path);
  if (!path_copy) return ENOMEM;
  char *dir, *last = NULL;
  int ret = ENOENT;
  for (dir = strtok_r(path_copy, ":", &last); dir; dir = strtok_r(NULL, ":", &last)) {
    size_t dlen = strlen(dir), flen = strlen(file);
    char *full = malloc(dlen + 1 + flen + 1);
    if (!full) { free(path_copy); return ENOMEM; }
    memcpy(full, dir, dlen);
    full[dlen] = '/';
    memcpy(full + dlen + 1, file, flen + 1);
    ret = posix_spawn(pid, full, fa, attr, argv, envp);
    free(full);
    if (ret == 0) break;
  }
  free(path_copy);
  return ret;
}

#endif /* __ANDROID__ && API < 28 */
#endif /* CMAKE_ANDROID_COMPAT_H */
