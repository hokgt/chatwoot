/*
 * wijaya_sop_sandbox.c — fail-closed Landlock + seccomp launcher for Marine SOP
 * parser subprocesses (Chatwoot Marine AI battery, SOP/OCR Blocker 2).
 * =============================================================================
 *
 * Compiled into the SOP derivative image ONLY (never the plain app image):
 *
 *   cc -O2 -Wall -Werror -static -o /usr/local/bin/wijaya-sop-sandbox \
 *     custom/wijaya/batteries/marine_ai/deploy/wijaya_sop_sandbox.c
 *
 * The parent (Marine::Documents::CommandRunner) spawns every native
 * Poppler/Tesseract command as:
 *
 *   su-exec marine_sop /usr/local/bin/wijaya-sop-sandbox <workspace> -- <argv...>
 *
 * with an env scrubbed to the exact allowlist below (unsetenv_others). This
 * launcher then applies a genuine OS sandbox BEFORE exec'ing the parser:
 *
 *   Landlock (deny-by-default filesystem policy):
 *     * the private per-document workspace: read/write/make/remove (NO execute);
 *     * exact runtime trees, READ-ONLY: /usr/lib, /lib, /etc/fonts,
 *       /usr/share/tessdata (eng+ind tessdata), /usr/share/fonts — with NO
 *       general /usr/bin read access (the four parsers carry their own exact
 *       read+execute rules below);
 *     * EXECUTE (+read) on exactly the four parser binaries and the musl
 *       dynamic loader (required for dynamic linking) — no other file carries
 *       execute. Exec mode additionally refuses any argv[3] that is not
 *       EXACTLY one of the four parsers. NOTE: that argv[3] allowlist only
 *       constrains the INITIAL exec target — once the parser binary itself is
 *       compromised, loader-invocation of other readable ELF files is NOT a
 *       hard executable boundary; the main containment layers are the scrubbed
 *       env, the deny-by-default Landlock filesystem policy, the complete
 *       network denial, and the seccomp process-escape/io_uring denial.
 *     * /dev/null and /dev/urandom (regular device nodes only).
 *     Everything else — /app, /app/storage, Rails config, unrelated /tmp,
 *     other workspaces, /proc, symlink escapes — is denied by default.
 *   Landlock net (kernel ABI >= 4): TCP bind/connect handled with an EMPTY
 *     allowlist, i.e. all TCP denied. On older kernels this part is skipped —
 *     seccomp below is the hard guarantee and denies socket() entirely.
 *   seccomp (classic BPF, no privileges required):
 *     * socket() and socketpair() return EPERM — no Internet, no DNS, no
 *       loopback, no Docker network, no Unix sockets of ANY kind;
 *     * io_uring_setup()/io_uring_enter()/io_uring_register() return EPERM —
 *       no io_uring side channel around the rest of the policy;
 *     * setsid() and setpgid() return EPERM — no process-escape (session or
 *       process-group detachment) out of the sandboxed child;
 *     * non-x86_64 architectures fail closed with EPERM.
 *
 * Fail-closed rules:
 *   * ANY setup failure (missing Landlock, bad rule, seccomp rejected,
 *     non-allowlisted env key) aborts BEFORE exec — exit code 126, one fixed
 *     stderr line, never a path/argv/env value.
 *   * The launcher never execs anything that is not in EXECUTE_PATHS.
 *   * The launcher runs only AFTER su-exec has dropped it to marine_sop, and it
 *     fail-closes (exit 126, before any policy or exec) unless its own process
 *     has ZERO effective AND permitted capabilities, verified with a direct
 *     capget(2) syscall (self-contained x86_64 UAPI below; /proc capability
 *     values are never read or printed). Capabilities are never granted to the
 *     child; su-exec clears them and the launcher verifies.
 *
 * Self-test mode (used by the deploy gate, runs the SAME policy first):
 *
 *   env -i LANG=C PATH=/usr/bin:/bin ... wijaya-sop-sandbox --selftest \
 *     <workspace> <probe-path>...
 *
 * verifies: exact env key allowlist, workspace write, every probe path is
 * unreadable, /bin/sh cannot be executed, no socket/socketpair can be created,
 * and io_uring_setup/enter/register, setsid and setpgid all return EPERM.
 * Prints WIJAYA_SOP_SELFTEST:PASS or WIJAYA_SOP_SELFTEST:FAIL:<token> and exits
 * 0/1. The env allowlist is enforced in self-test mode too, so the gate can
 * prove a non-allowlisted env var is rejected fail-closed (env -i CANARY=1...).
 * The zero-capability contract is exercised by the deploy gate too: the gate
 * always runs the selftest through su-exec, so a PASS also proves the
 * launcher's own capget check accepted the su-exec-cleared capability sets.
 *
 * The ENV_ALLOWLIST / EXECUTE_PATHS / EXEC_MODE_ALLOWLIST tables below must
 * mirror Marine::Documents::CommandRunner (CHILD_ENV_KEYS /
 * ALLOWED_EXECUTABLES); the command runner spec cross-checks them so they
 * cannot drift.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>

#if !defined(__x86_64__)
#error "wijaya_sop_sandbox.c supports x86_64 only (fixed seccomp syscall numbers)"
#endif

/* Any policy/setup failure maps to this exit code (parent sees a stable,
 * non-success child exit; stderr is drained by the parent and never stored). */
#define EXIT_POLICY 126

/* ---------------------------------------------------------------------------
 * Self-contained Linux UAPI (no kernel headers required; musl-dev + gcc only).
 * ------------------------------------------------------------------------- */
#ifndef PR_SET_NO_NEW_PRIVS
#define PR_SET_NO_NEW_PRIVS 38
#endif
#ifndef PR_SET_SECCOMP
#define PR_SET_SECCOMP 22
#endif
#define WIJAYA_SECCOMP_MODE_FILTER 2
#define WIJAYA_SECCOMP_RET_ALLOW 0x7fff0000U
#define WIJAYA_SECCOMP_RET_ERRNO(x) (0x00050000U | ((x) & 0xffffU))

struct wijaya_sock_filter { uint16_t code; uint8_t jt; uint8_t jf; uint32_t k; };
struct wijaya_sock_fprog { uint16_t len; struct wijaya_sock_filter *filter; };

#define WIJAYA_BPF_LD 0x00
#define WIJAYA_BPF_W 0x00
#define WIJAYA_BPF_ABS 0x20
#define WIJAYA_BPF_JMP 0x05
#define WIJAYA_BPF_JEQ 0x10
#define WIJAYA_BPF_RET 0x06
#define WIJAYA_BPF_K 0x00
#define WIJAYA_AUDIT_ARCH_X86_64 0xc000003eU

#ifndef __NR_landlock_create_ruleset
#define __NR_landlock_create_ruleset 444
#endif
#ifndef __NR_landlock_add_rule
#define __NR_landlock_add_rule 445
#endif
#ifndef __NR_landlock_restrict_self
#define __NR_landlock_restrict_self 446
#endif
#ifndef __NR_io_uring_setup
#define __NR_io_uring_setup 425
#endif
#ifndef __NR_io_uring_enter
#define __NR_io_uring_enter 426
#endif
#ifndef __NR_io_uring_register
#define __NR_io_uring_register 427
#endif
#ifndef __NR_setsid
#define __NR_setsid 112
#endif
#ifndef __NR_setpgid
#define __NR_setpgid 109
#endif
/* Direct capget(2) UAPI (x86_64 syscall 125; self-contained, no kernel
 * headers). Used ONLY to verify this already-su-exec'd process carries ZERO
 * effective and permitted capabilities. Capability values are never printed,
 * and /proc is never consulted for them (the gate contract forbids reading or
 * printing /proc capability values). */
#ifndef __NR_capget
#define __NR_capget 125
#endif
#define WIJAYA_CAP_VERSION_3 0x20080522U /* real uapi _LINUX_CAPABILITY_VERSION_3 */
struct wijaya_cap_header { uint32_t version; int32_t pid; };
struct wijaya_cap_data {
  uint32_t effective;
  uint32_t permitted;
  uint32_t inheritable;
};

/* Landlock UAPI (linux/landlock.h, stable since kernel 5.13). */
#define WIJAYA_LL_CREATE_VERSION (1U << 0)
#define WIJAYA_LL_RULE_PATH_BENEATH 1
struct wijaya_landlock_ruleset_attr {
  uint64_t handled_access_fs;
  uint64_t handled_access_net;
};
struct wijaya_landlock_path_beneath_attr {
  uint64_t allowed_access;
  int32_t parent_fd;
} __attribute__((packed));

#define WIJAYA_LL_FS_EXECUTE (1ULL << 0)
#define WIJAYA_LL_FS_WRITE_FILE (1ULL << 1)
#define WIJAYA_LL_FS_READ_FILE (1ULL << 2)
#define WIJAYA_LL_FS_READ_DIR (1ULL << 3)
#define WIJAYA_LL_FS_REMOVE_DIR (1ULL << 4)
#define WIJAYA_LL_FS_REMOVE_FILE (1ULL << 5)
#define WIJAYA_LL_FS_MAKE_CHAR (1ULL << 6)
#define WIJAYA_LL_FS_MAKE_DIR (1ULL << 7)
#define WIJAYA_LL_FS_MAKE_REG (1ULL << 8)
#define WIJAYA_LL_FS_MAKE_SOCK (1ULL << 9)
#define WIJAYA_LL_FS_MAKE_FIFO (1ULL << 10)
#define WIJAYA_LL_FS_MAKE_BLOCK (1ULL << 11)
#define WIJAYA_LL_FS_MAKE_SYM (1ULL << 12)
#define WIJAYA_LL_FS_REFER (1ULL << 13)    /* ABI 2 */
#define WIJAYA_LL_FS_TRUNCATE (1ULL << 14) /* ABI 3 */
#define WIJAYA_LL_NET_BIND_TCP (1ULL << 0)    /* ABI 4 */
#define WIJAYA_LL_NET_CONNECT_TCP (1ULL << 1)

/* ---------------------------------------------------------------------------
 * Policy tables — MUST mirror Marine::Documents::CommandRunner (Ruby side).
 * ------------------------------------------------------------------------- */
/* Exact env keys the parser child may receive (CommandRunner child_env). */
static const char *const ENV_ALLOWLIST[] = {
  "HOME", "LANG", "LC_ALL", "PATH", "TMPDIR", "XDG_CACHE_HOME", NULL
};
/* Read-only runtime trees (parser libraries, musl loader, /etc/fonts,
 * tessdata). Deliberately NO general /usr/bin read access: the only /usr/bin
 * files the parsers ever need are the four binaries themselves, covered by
 * their exact read+execute rules in EXECUTE_PATHS. Tesseract language data
 * lives at /usr/share/tessdata on Alpine (tesseract-ocr-data-eng/-ind), as
 * reported by the running derivative image (tesseract --list-langs =>
 * "/usr/share/tessdata/"); /usr/share/tesseract-ocr does not exist there, so
 * it is not carried here. */
static const char *const READ_ONLY_PATHS[] = {
  "/usr/lib", "/lib", "/etc/fonts",
  "/usr/share/tessdata", "/usr/share/fonts", NULL
};
/* The ONLY executables that can be executed under the sandbox. An entry
 * absent from a given image build is simply skipped — the binary then cannot
 * be executed, which is still fail-closed. /lib/ld-musl-x86_64.so.1 is the
 * musl dynamic loader the dynamically linked Alpine parser binaries need at
 * exec time (it must stay executable for dynamic linking). Landlock EXECUTE
 * on the loader does NOT by itself make loader-invocation of other ELF files
 * impossible — any file still readable under this policy (shared libraries in
 * /usr/lib, files inside the private workspace) could be loaded by it; that
 * residual is bounded by the explicit exec-mode target allowlist below, by
 * the parent-side resolve_executable allowlist, and by seccomp denying
 * every socket to whatever code does run. */
static const char *const EXECUTE_PATHS[] = {
  "/usr/bin/pdfinfo", "/usr/bin/pdftotext", "/usr/bin/pdftoppm",
  "/usr/bin/tesseract", "/lib/ld-musl-x86_64.so.1", NULL
};
/* Exec-mode argv[3] allowlist: EXACTLY the four parser binaries — never the
 * musl loader, never anything else. This is the explicit fail-closed exec
 * target contract, checked in main() BEFORE the policy is applied. It only
 * constrains the INITIAL exec target: after the parser itself is compromised,
 * loader execution of other readable ELF files is NOT a hard executable
 * boundary — the main containment is the scrubbed env, the deny-by-default
 * Landlock filesystem policy, the complete network denial, and the seccomp
 * process-escape/io_uring denial. The Landlock EXECUTE rules are defense in
 * depth on top of it. */
static const char *const EXEC_MODE_ALLOWLIST[] = {
  "/usr/bin/pdfinfo", "/usr/bin/pdftotext", "/usr/bin/pdftoppm",
  "/usr/bin/tesseract", NULL
};
/* Device nodes the parsers legitimately need. Nothing else under /dev. */
static const char *const DEVICE_READ_PATHS[] = { "/dev/urandom", NULL };
static const char *const DEVICE_RW_PATHS[] = { "/dev/null", NULL };

/* --------------------------------------------------------------------- */
static void die_policy(void) {
  /* ONE fixed line on stderr (never captured/stored by the parent). */
  dprintf(STDERR_FILENO, "wijaya-sop-sandbox: policy failure\n");
  _exit(EXIT_POLICY);
}

/* Final independent review: the parent compose service keeps cap_drop ALL and
 * adds only CHOWN/SETUID/SETGID/KILL; the CHILD must have zero capabilities.
 * su-exec drops the launcher to marine_sop (setuid away from uid 0 clears the
 * effective and permitted sets), and this check turns zero-caps into a hard
 * fail-closed contract: if the launcher is ever invoked with ANY effective or
 * permitted capability (misconfigured parent, capability smuggling), it aborts
 * BEFORE applying the policy or exec'ing the parser. Inheritable is not
 * checked: it can never grant rights without a permitted bit, and with the
 * permitted set empty exec can never re-acquire anything. */
static void require_zero_capabilities(void) {
  struct wijaya_cap_header hdr;
  struct wijaya_cap_data data[2];
  memset(&hdr, 0, sizeof(hdr));
  hdr.version = WIJAYA_CAP_VERSION_3;
  hdr.pid = 0; /* this process */
  memset(data, 0, sizeof(data));
  if (syscall(__NR_capget, &hdr, &data[0]) != 0) die_policy();
  if (data[0].effective != 0 || data[0].permitted != 0) die_policy();
  if (data[1].effective != 0 || data[1].permitted != 0) die_policy();
}

static uint64_t handled_fs_for(int abi) {
  if (abi >= 3) return 0x7fffULL; /* v3: + TRUNCATE */
  if (abi == 2) return 0x3fffULL; /* v2: + REFER */
  return 0x1fffULL;               /* v1 */
}

/* Adds a path-beneath rule. A path that does not exist (ENOENT) is simply
 * skipped: an absent allowlisted tree is still deny-by-default for the child
 * and cannot weaken the policy. Any other failure is fatal (fail closed). */
static void add_beneath(int ruleset, const char *path, uint64_t access) {
  struct wijaya_landlock_path_beneath_attr rule;
  int fd = open(path, O_PATH | O_CLOEXEC);
  if (fd < 0) {
    if (errno == ENOENT) return;
    die_policy();
  }
  memset(&rule, 0, sizeof(rule));
  rule.allowed_access = access;
  rule.parent_fd = fd;
  if (syscall(__NR_landlock_add_rule, ruleset, WIJAYA_LL_RULE_PATH_BENEATH,
              &rule, 0) != 0)
    die_policy();
  close(fd);
}

static void install_seccomp(void) {
  /* Deny socket()/socketpair() outright: no Internet, no DNS (UDP or TCP), no
   * loopback, no Docker bridge, no Unix sockets, no socketpair IPC. Deny
   * io_uring_setup/enter/register: no io_uring side channel. Deny
   * setsid/setpgid: the sandboxed child cannot detach into a new session or
   * process group (process escape). The parser binaries need none of these.
   * Non-x86_64 arches fail closed with EPERM (checked at compile time above). */
  static struct wijaya_sock_filter filter[] = {
    { WIJAYA_BPF_LD | WIJAYA_BPF_W | WIJAYA_BPF_ABS, 0, 0, 4 },
    { WIJAYA_BPF_JMP | WIJAYA_BPF_JEQ | WIJAYA_BPF_K, 1, 0,
      WIJAYA_AUDIT_ARCH_X86_64 },
    { WIJAYA_BPF_RET | WIJAYA_BPF_K, 0, 0,
      WIJAYA_SECCOMP_RET_ERRNO(EPERM) },
    { WIJAYA_BPF_LD | WIJAYA_BPF_W | WIJAYA_BPF_ABS, 0, 0, 0 },
    { WIJAYA_BPF_JMP | WIJAYA_BPF_JEQ | WIJAYA_BPF_K, 0, 1, __NR_socket },
    { WIJAYA_BPF_RET | WIJAYA_BPF_K, 0, 0,
      WIJAYA_SECCOMP_RET_ERRNO(EPERM) },
    { WIJAYA_BPF_JMP | WIJAYA_BPF_JEQ | WIJAYA_BPF_K, 0, 1,
      __NR_socketpair },
    { WIJAYA_BPF_RET | WIJAYA_BPF_K, 0, 0,
      WIJAYA_SECCOMP_RET_ERRNO(EPERM) },
    { WIJAYA_BPF_JMP | WIJAYA_BPF_JEQ | WIJAYA_BPF_K, 0, 1,
      __NR_io_uring_setup },
    { WIJAYA_BPF_RET | WIJAYA_BPF_K, 0, 0,
      WIJAYA_SECCOMP_RET_ERRNO(EPERM) },
    { WIJAYA_BPF_JMP | WIJAYA_BPF_JEQ | WIJAYA_BPF_K, 0, 1,
      __NR_io_uring_enter },
    { WIJAYA_BPF_RET | WIJAYA_BPF_K, 0, 0,
      WIJAYA_SECCOMP_RET_ERRNO(EPERM) },
    { WIJAYA_BPF_JMP | WIJAYA_BPF_JEQ | WIJAYA_BPF_K, 0, 1,
      __NR_io_uring_register },
    { WIJAYA_BPF_RET | WIJAYA_BPF_K, 0, 0,
      WIJAYA_SECCOMP_RET_ERRNO(EPERM) },
    { WIJAYA_BPF_JMP | WIJAYA_BPF_JEQ | WIJAYA_BPF_K, 0, 1,
      __NR_setsid },
    { WIJAYA_BPF_RET | WIJAYA_BPF_K, 0, 0,
      WIJAYA_SECCOMP_RET_ERRNO(EPERM) },
    { WIJAYA_BPF_JMP | WIJAYA_BPF_JEQ | WIJAYA_BPF_K, 0, 1,
      __NR_setpgid },
    { WIJAYA_BPF_RET | WIJAYA_BPF_K, 0, 0,
      WIJAYA_SECCOMP_RET_ERRNO(EPERM) },
    { WIJAYA_BPF_RET | WIJAYA_BPF_K, 0, 0, WIJAYA_SECCOMP_RET_ALLOW },
  };
  struct wijaya_sock_fprog prog;
  prog.len = (uint16_t)(sizeof(filter) / sizeof(filter[0]));
  prog.filter = filter;
  if (prctl(PR_SET_SECCOMP, WIJAYA_SECCOMP_MODE_FILTER, &prog, 0, 0) != 0)
    die_policy();
}

/* Applies the full Landlock + seccomp policy for `workspace`. */
static void apply_policy(const char *workspace) {
  struct wijaya_landlock_ruleset_attr attr;
  int abi, ruleset, i;
  uint64_t ro, ws_access;

  /* Probe the kernel Landlock ABI. <1 means no Landlock at all: fail closed. */
  abi = (int)syscall(__NR_landlock_create_ruleset, NULL, (size_t)0,
                     WIJAYA_LL_CREATE_VERSION);
  if (abi < 1) die_policy();

  /* Ruleset handles ALL filesystem rights the kernel supports, plus TCP
   * bind/connect when the ABI has it (>=4). Anything not explicitly allowed
   * below is therefore denied. */
  memset(&attr, 0, sizeof(attr));
  attr.handled_access_fs = handled_fs_for(abi);
  attr.handled_access_net = WIJAYA_LL_NET_BIND_TCP | WIJAYA_LL_NET_CONNECT_TCP;
  ruleset = (int)syscall(__NR_landlock_create_ruleset, &attr, sizeof(attr), 0);
  if (ruleset < 0) {
    /* Kernel without net support (ABI < 4): retry filesystem-only. seccomp
     * still denies socket() entirely, so this is not a policy weakening. */
    attr.handled_access_net = 0;
    ruleset = (int)syscall(__NR_landlock_create_ruleset, &attr, sizeof(attr), 0);
  }
  if (ruleset < 0) die_policy();

  /* The private per-document workspace: full read/write/make/remove, but never
   * execute. Everything else in /tmp is NOT beneath this rule and stays denied. */
  ws_access = handled_fs_for(abi) & ~(uint64_t)WIJAYA_LL_FS_EXECUTE;
  add_beneath(ruleset, workspace, ws_access);

  /* Read-only runtime trees. */
  ro = WIJAYA_LL_FS_READ_FILE | WIJAYA_LL_FS_READ_DIR;
  for (i = 0; READ_ONLY_PATHS[i]; i++)
    add_beneath(ruleset, READ_ONLY_PATHS[i], ro);

  /* Executable: exactly the parser binaries and the musl loader. Regular-file
   * rules may only carry file rights (READ_DIR/MAKE_* would be EINVAL), so the
   * mask here is exactly READ_FILE + EXECUTE. */
  for (i = 0; EXECUTE_PATHS[i]; i++)
    add_beneath(ruleset, EXECUTE_PATHS[i],
                WIJAYA_LL_FS_READ_FILE | WIJAYA_LL_FS_EXECUTE);

  /* Device nodes only. */
  for (i = 0; DEVICE_READ_PATHS[i]; i++)
    add_beneath(ruleset, DEVICE_READ_PATHS[i], WIJAYA_LL_FS_READ_FILE);
  for (i = 0; DEVICE_RW_PATHS[i]; i++)
    add_beneath(ruleset, DEVICE_RW_PATHS[i],
                WIJAYA_LL_FS_READ_FILE | WIJAYA_LL_FS_WRITE_FILE);

  /* TCP handled with an EMPTY allowlist => all TCP bind/connect denied
   * (nothing to add: rulesets are deny-by-default for handled rights). */

  if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) die_policy();
  if (syscall(__NR_landlock_restrict_self, ruleset, 0) != 0) die_policy();
  close(ruleset);

  install_seccomp();
}

/* Exact env key allowlist (values are never inspected or printed). */
extern char **environ;

static int env_key_allowed(const char *kv) {
  size_t i, keylen = strcspn(kv, "=");
  for (i = 0; ENV_ALLOWLIST[i]; i++) {
    if (strlen(ENV_ALLOWLIST[i]) == keylen &&
        strncmp(kv, ENV_ALLOWLIST[i], keylen) == 0)
      return 1;
  }
  return 0;
}

static void enforce_env_allowlist(void) {
  char **e;
  for (e = environ; *e; e++) {
    if (!env_key_allowed(*e)) die_policy();
  }
}

/* --------------------------------------------------------------------------
 * Self-test (deploy gate). Prints a stable verdict line; never prints a path.
 * ------------------------------------------------------------------------ */
static void selftest_fail(const char *token) {
  printf("WIJAYA_SOP_SELFTEST:FAIL:%s\n", token);
  fflush(stdout);
  _exit(1);
}

static void run_selftest(const char *workspace, char *const probes[]) {
  char path[4096];
  int fd, status, sv[2], s, i;
  pid_t pid;
  char *child_argv[] = { "/bin/sh", "-c", "exit 9", NULL };
  char *child_env[] = { NULL };

  /* 1) the workspace must be writable (create + unlink a file inside it). */
  if (snprintf(path, sizeof(path), "%s/.wijaya-selftest", workspace) >=
      (int)sizeof(path))
    selftest_fail("workspace");
  fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0600);
  if (fd < 0) selftest_fail("workspace");
  if (write(fd, "x", 1) != 1) selftest_fail("workspace");
  close(fd);
  if (unlink(path) != 0) selftest_fail("workspace");

  /* 2) every probe path must be UNREADABLE (decoys, symlink escapes, /app,
   * /proc, unrelated /tmp — all outside the allowed trees). */
  for (i = 0; probes[i]; i++) {
    fd = open(probes[i], O_RDONLY);
    if (fd >= 0) {
      close(fd);
      selftest_fail("probe");
    }
  }

  /* 3) exec of a non-allowlisted binary must be blocked (Landlock EXECUTE). */
  pid = fork();
  if (pid < 0) selftest_fail("exec");
  if (pid == 0) {
    execve("/bin/sh", child_argv, child_env);
    _exit(0); /* exec was blocked (expected) */
  }
  if (waitpid(pid, &status, 0) != pid) selftest_fail("exec");
  if (!(WIFEXITED(status) && WEXITSTATUS(status) == 0)) selftest_fail("exec");

  /* 4) no socket of any kind may be created (Internet, IPv6, Unix, pairs). */
  /* (checked below together with the io_uring / process-escape denials) */
  s = socket(AF_INET, SOCK_STREAM, 0);
  if (s >= 0) { close(s); selftest_fail("socket"); }
  s = socket(AF_INET6, SOCK_STREAM, 0);
  if (s >= 0) { close(s); selftest_fail("socket"); }
  s = socket(AF_UNIX, SOCK_STREAM, 0);
  if (s >= 0) { close(s); selftest_fail("socket"); }
  if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) == 0) {
    close(sv[0]); close(sv[1]);
    selftest_fail("socketpair");
  }

  /* 5) io_uring must be completely unavailable (no side channel around the
   * Landlock/seccomp policy), and the child must not be able to detach into a
   * new session or process group (process escape). Every one of these must
   * return exactly -1/EPERM under the filter. */
  if (syscall(__NR_io_uring_setup, 0U, 0U, 0U) != -1 || errno != EPERM)
    selftest_fail("io_uring");
  if (syscall(__NR_io_uring_enter, 0, 0, 0, 0) != -1 || errno != EPERM)
    selftest_fail("io_uring");
  if (syscall(__NR_io_uring_register, 0, 0, 0, 0) != -1 || errno != EPERM)
    selftest_fail("io_uring");
  if (setsid() != -1 || errno != EPERM)
    selftest_fail("process-escape");
  if (setpgid(0, 0) != -1 || errno != EPERM)
    selftest_fail("process-escape");

  printf("WIJAYA_SOP_SELFTEST:PASS\n");
  fflush(stdout);
  _exit(0);
}

static int exec_target_allowed(const char *path) {
  int i;
  for (i = 0; EXEC_MODE_ALLOWLIST[i]; i++)
    if (strcmp(path, EXEC_MODE_ALLOWLIST[i]) == 0) return 1;
  return 0;
}

int main(int argc, char **argv) {
  if (argc >= 2 && strcmp(argv[1], "--selftest") == 0) {
    if (argc < 3) die_policy();
    enforce_env_allowlist();
    require_zero_capabilities();
    apply_policy(argv[2]);
    run_selftest(argv[2], &argv[3]);
    die_policy(); /* run_selftest always exits */
  }

  /* exec mode: wijaya-sop-sandbox <workspace> -- <parser> [args...]
   * argv[3] must be EXACTLY one of the four allowlisted parser binaries
   * (EXEC_MODE_ALLOWLIST): the launcher never execs anything else — including
   * the musl loader or any other ELF file readable under the policy. Checked
   * before the policy is applied so a disallowed target never reaches exec. */
  if (argc < 4 || strcmp(argv[2], "--") != 0) die_policy();
  enforce_env_allowlist();
  require_zero_capabilities();
  if (!exec_target_allowed(argv[3])) die_policy();
  apply_policy(argv[1]);
  if (chdir(argv[1]) != 0) die_policy();
  execv(argv[3], &argv[3]);
  die_policy();
}
