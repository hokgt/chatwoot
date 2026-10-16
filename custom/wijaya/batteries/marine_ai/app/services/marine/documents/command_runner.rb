# Safe external-command runner for SOP extraction/OCR (Commit 1C, Blocker 2).
#
# SECURITY / ROBUSTNESS GUARANTEES
#   * argv is executed DIRECTLY (Open3 + process spawn) — never an interpolated
#     shell string, never `/bin/sh -c`. Filenames and page numbers are passed as
#     discrete argv elements, so shell metacharacters can never be interpreted.
#   * CHILD ENVIRONMENT IS A FIXED MINIMAL ALLOWLIST (Blocker 2): every command is
#     spawned with unsetenv_others + close_others, so NOTHING is inherited from the
#     Rails/Sidekiq process — no DB/Redis/Rails/integration secrets, no proxy vars,
#     no LD_*/Ruby/Bundler injection vars. The child sees only PATH/LANG/LC_ALL and a
#     workspace-scoped HOME/TMPDIR/XDG_CACHE_HOME (see CHILD_ENV_KEYS).
#   * every native parser runs INSIDE a genuine OS sandbox before exec (Blocker 2):
#     [su-exec marine_sop /usr/local/bin/wijaya-sop-sandbox <workspace> -- <argv>].
#     The launcher (deploy/wijaya_sop_sandbox.c, compiled into the SOP derivative
#     image) applies a fail-closed Landlock policy (workspace R/W; exact runtime
#     trees R/O — libraries, /etc, /usr/share/tessdata, fonts — with NO general
#     /usr/bin read access: only the four parser binaries carry exact read+execute
#     rules; exec mode additionally refuses any argv[3] that is not EXACTLY one of
#     the four parsers, the musl loader included (that argv[3] allowlist constrains ONLY the
#     initial exec target: after the parser binary itself is compromised,
#     loader execution of other readable ELF files is NOT a hard executable
#     boundary; the main containment is the scrubbed env, the deny-by-default
#     Landlock filesystem policy — /app, /app/storage, Rails config, unrelated
#     /tmp, other workspaces, /proc and symlink escapes all denied — the
#     complete network denial, and the seccomp process-escape denial) plus
#     a seccomp filter that makes socket()/socketpair(), io_uring_setup/
#     enter/register, setsid and setpgid all EPERM — no Internet, DNS,
#     loopback, Docker network or Unix sockets — and it independently re-enforces
#     the exact child env key allowlist.
#   * FAIL CLOSED (Blocker 2): when the sandbox contract is active, a missing
#     marine_sop account, su-exec binary, sandbox launcher or allowlisted parser
#     aborts the whole document with the stable dependency error BEFORE any
#     workspace is created. Unsandboxed direct execution exists ONLY behind the
#     explicit safe test contract (MARINE_SOP_SANDBOX_TEST_ONLY=1 in Rails test env).
#   * a single hard extraction/OCR deadline (default 120s) is shared across EVERY
#     command run through one runner instance (i.e. per DOCUMENT, not per page). The
#     SAME absolute deadline bounds BOTH the child waiter AND the two pipe drains, so a
#     descendant that keeps stdout/stderr open after the leader exits can never make a
#     drain join block past the deadline.
#   * a timed-out (or drain-blocked) child's whole process GROUP is SIGKILLed; the Open3
#     waiter thread reaps it so no zombie survives, and the local pipe ends are closed so
#     any reader still blocked on a descendant's copy is released.
#   * after the leader completes normally, any RESIDUAL member of its original
#     process group (a background descendant holding no pipe) is also SIGKILLed
#     so a parser cannot leave orphans behind; a single kill syscall against an
#     empty group returns ESRCH immediately, so there is no latency when none.
#   * stdout and stderr are drained CONCURRENTLY by separate threads so a child can
#     never deadlock on a full pipe; stored stdout is bounded, and stderr is drained
#     but NEVER captured/exposed.
#   * every subprocess is spawned with conservative RLIMITs (address space, CPU, output
#     file size, core, process count) so a pathological input cannot exhaust host memory,
#     disk, or CPU even before the wall deadline fires.
#   * all temporary files live inside a single private directory that is always removed
#     in `ensure` (via `.open`).
#   * a missing binary maps to a stable dependency error; results/errors are stable
#     objects that leak no path, command line, env values, or raw stderr.
require 'open3'
require 'tmpdir'
require 'fileutils'
require 'etc'
# Explicitly required (final independent review): the fd-backed fchown/fchmod
# workspace grants below go through libc via Fiddle, so the runner must load it
# itself and never rely on Reline (or anything else) loading Fiddle incidentally.
require 'fiddle'

module Marine
  module Documents
    class CommandRunner # rubocop:disable Metrics/ClassLength -- one cohesive security boundary: deadline/pipe/rlimit management, env scrub, and the fail-closed sandbox wiring belong together so no piece can drift out of sync
      GLOBAL_DEADLINE_SECONDS = 120
      # Per-command captured-stdout cap. Bounded well above any legitimate pdftotext /
      # pdfinfo / tesseract page output; the FINAL persisted content is separately capped
      # at 200k characters by TextNormalizer.
      MAX_OUTPUT_BYTES = 1 * 1024 * 1024
      READ_CHUNK_BYTES = 64 * 1024
      # Grace given, after a SIGKILL, for the Open3 waiter thread to reap the leader and
      # for the drain threads to finish before they are force-killed and joined.
      TERMINATE_GRACE_SECONDS = 2

      # Unprivileged account external OCR/Poppler commands are dropped to in a derived
      # image. su-exec re-execs the target retaining the RLIMITs applied by the parent.
      SOP_SUBPROCESS_USER = 'marine_sop'.freeze
      SU_EXEC_CANDIDATES = %w[/sbin/su-exec /usr/sbin/su-exec /usr/bin/su-exec /bin/su-exec].freeze

      # Blocker 2: absolute path of the fail-closed Landlock + seccomp launcher that is
      # compiled into the SOP derivative image from deploy/wijaya_sop_sandbox.c. The
      # launcher independently re-enforces CHILD_ENV_KEYS and EXECUTE_PATHS, so the two
      # sides cannot silently drift (the spec cross-checks the tables).
      SANDBOX_LAUNCHER = '/usr/local/bin/wijaya-sop-sandbox'.freeze
      # The ONLY executables this runner may invoke, as absolute paths inside the
      # derivative image. Mirrors EXECUTE_PATHS in deploy/wijaya_sop_sandbox.c. In
      # sandbox mode argv[0] must resolve to one of these or the run fails closed with
      # the stable extraction error.
      ALLOWED_EXECUTABLES = {
        'pdfinfo' => '/usr/bin/pdfinfo',
        'pdftotext' => '/usr/bin/pdftotext',
        'pdftoppm' => '/usr/bin/pdftoppm',
        'tesseract' => '/usr/bin/tesseract'
      }.freeze
      # Exact child environment key allowlist (mirrors ENV_ALLOWLIST in the launcher).
      CHILD_ENV_KEYS = %w[HOME LANG LC_ALL PATH TMPDIR XDG_CACHE_HOME].freeze
      # Deterministic minimal PATH for the parser child (binaries are invoked by
      # absolute path; nothing else should be reachable).
      CHILD_PATH = '/usr/bin:/bin'.freeze
      # Explicit safe test contract: the ONLY way unsandboxed direct execution is
      # allowed, and only inside the Rails test environment. Never set in production
      # (check_deploy_contract.sh enforces the overlay never carries it).
      TEST_ONLY_OPT_OUT = 'MARINE_SOP_SANDBOX_TEST_ONLY'.freeze

      # Conservative subprocess resource limits. Ample for normal Poppler rendering and
      # Tesseract LSTM OCR of a single <=4096px SOP page on musl, but bounded so a hostile
      # input cannot exhaust host memory, disk, or CPU even before the wall deadline fires.
      RLIMIT_AS_BYTES = 1 * 1024 * 1024 * 1024   # ~1 GiB address space
      RLIMIT_FSIZE_BYTES = 64 * 1024 * 1024      # 64 MiB per single output file
      RLIMIT_NPROC = 256                         # bound fork bombs; ample for OCR threads
      # RLIMIT_CPU is CUMULATIVE CPU seconds across ALL threads of the process, so a
      # multi-threaded Tesseract can burn N x wallclock CPU seconds well before the 120s
      # wall deadline. Setting rlimit_cpu to the wall deadline would SIGKILL a legitimate
      # parallel OCR prematurely; this separate, larger CPU budget is the real backstop
      # against a runaway loop while the wall deadline remains the primary bound.
      RLIMIT_CPU_SECONDS = 480                   # cumulative CPU-seconds backstop (multi-thread aware)

      # Stable result. Deliberately exposes ONLY captured stdout and a success flag —
      # never stderr, the argv, or the exit signal details.
      Result = Struct.new(:stdout, :ok, keyword_init: true)

      # Detects, ONCE per process, whether external commands can be dropped to the locked
      # marine_sop account: only when we run as root (a required precondition for su-exec
      # to switch users) AND both the su-exec binary and the account are present. Returns
      # a frozen descriptor { binary:, user:, uid:, gid: } or nil (no drop possible).
      def self.compute_privilege_drop
        return nil unless Process.uid.zero?

        binary = SU_EXEC_CANDIDATES.find { |candidate| File.executable?(candidate) }
        return nil unless binary

        pw = Etc.getpwnam(SOP_SUBPROCESS_USER)
        { binary: binary, user: SOP_SUBPROCESS_USER, uid: pw.uid, gid: pw.gid }.freeze
      rescue ArgumentError
        nil
      end

      # The ONLY sanctioned non-sandboxed mode (Blocker 2): the explicit test contract.
      # Requires BOTH the opt-out env var and the Rails test environment, so a stray
      # production env var can never disable the sandbox.
      def self.test_contract?
        ENV[TEST_ONLY_OPT_OUT] == '1' && defined?(Rails) && Rails.env.test?
      end

      # Full sandbox descriptor or nil. In enforced mode (anything outside the explicit
      # test contract) a missing component — marine_sop account, su-exec, launcher, or
      # any of the four allowlisted parser binaries — RAISES the stable dependency
      # error instead of ever running unsandboxed. Not memoized when nil so the test
      # contract can be toggled per example.
      def self.sandbox
        @sandbox = compute_sandbox if !defined?(@sandbox) || @sandbox.nil?
        @sandbox
      end

      def self.compute_sandbox
        drop = compute_privilege_drop
        # Fail closed BEFORE any workspace exists: the enforced sandbox contract
        # requires the marine_sop account + su-exec (drop), the launcher AND all
        # four allowlisted parser binaries present and executable in this image.
        contract_ready =
          !drop.nil? && File.executable?(SANDBOX_LAUNCHER) &&
          ALLOWED_EXECUTABLES.values.all? { |path| File.executable?(path) }
        unless contract_ready
          return nil if test_contract?

          raise Marine::Documents::Errors::SopProcessingDependencyUnavailableError
        end
        drop.merge(launcher: SANDBOX_LAUNCHER).freeze
      end

      # Non-raising probe for specs/gates: is the full sandbox contract available here?
      def self.sandbox_available?
        !sandbox.nil?
      rescue Marine::Documents::Errors::SopProcessingError
        false
      end

      # Opens a runner with a fresh private workspace + shared deadline and guarantees
      # the workspace is removed afterwards.
      def self.open(deadline_seconds: GLOBAL_DEADLINE_SECONDS)
        runner = new(deadline_seconds: deadline_seconds)
        yield runner
      ensure
        runner&.cleanup!
      end

      attr_reader :dir

      def initialize(deadline_seconds: GLOBAL_DEADLINE_SECONDS)
        # Blocker 2: fail closed BEFORE creating any workspace when the sandbox
        # contract is active but incomplete. Never retry unsandboxed.
        @sandbox = self.class.sandbox
        @deadline = monotonic_now + deadline_seconds
        @dir = Dir.mktmpdir('marine-sop')
        @seq = 0
        prepare_child_env_dirs
        grant_workspace_access
      end

      # Returns a unique path INSIDE the private workspace for a caller-controlled base
      # label. The label is sanitized and made unique, so it can never traverse out of
      # the workspace.
      def workspace_path(label)
        @seq += 1
        safe = label.to_s.gsub(/[^a-zA-Z0-9._-]/, '_')
        File.join(@dir, "#{safe}-#{@seq}")
      end

      # Linux O_NOFOLLOW (0o400000 on x86_64): open() fails with ELOOP when the
      # FINAL path component is a symlink, so the accepted fd can never have
      # been obtained through a symlinked filename.
      O_NOFOLLOW = 0o400000

      # Marks a workspace INPUT file readable by the dropped marine_sop subprocess user
      # (group read) so a privilege-dropped Poppler/Tesseract can open it. A no-op when
      # no sandbox drop is active (test contract). Accepts ONLY a regular file whose
      # canonical fd target is beneath the private workspace: the path is opened with
      # O_NOFOLLOW (symlinked filename rejected), the fd is fstat-verified regular
      # (never a directory/device/socket), and the fd is resolved through
      # /proc/self/fd so even an intermediate symlink escape resolves to the real
      # target before it is compared with @dir. Anything else — outside @dir, a
      # symlink, or a non-regular file — fails closed with the stable extraction
      # error before any ownership/mode change is made. The fchown/fchmod grant
      # itself is applied to the SAME open verified fd, never to a path that is
      # reopened after verification, so a path swap cannot race the grant.
      def grant_read(path)
        return path unless @sandbox

        with_workspace_fd(path) do |io|
          fd = io.fileno
          fchown_fd(fd, nil, @sandbox[:gid])
          fchmod_fd(fd, 0o640)
        end
        path
      end

      # Runs argv to completion (or the shared deadline) and returns a Result.
      # In sandbox mode argv[0] must be one of ALLOWED_EXECUTABLES (by name or
      # absolute path); anything else fails closed with the stable extraction error.
      def run(*argv)
        argv = argv.map(&:to_s)
        raise Marine::Documents::Errors::SopExtractionFailedError if argv.empty?
        raise Marine::Documents::Errors::SopOcrTimeoutError if remaining_seconds <= 0

        capture(resolve_executable(argv))
      end

      def cleanup!
        FileUtils.remove_entry(@dir) if @dir && Dir.exist?(@dir)
      rescue StandardError
        nil
      end

      private

      # Blocker 2: maps argv[0] to the absolute allowlisted parser path (accepting
      # either the short name or the exact absolute path). Returns argv unchanged
      # without a sandbox (test contract only).
      def resolve_executable(argv)
        return argv unless @sandbox

        first = argv.first
        allowed =
          if first.start_with?('/')
            ALLOWED_EXECUTABLES.value?(first) ? first : nil
          else
            ALLOWED_EXECUTABLES[first]
          end
        raise Marine::Documents::Errors::SopExtractionFailedError unless allowed

        [allowed, *argv.drop(1)]
      end

      # Exact fixed child environment (Blocker 2). Combined with
      # unsetenv_others: true this is a complete scrub: no DB/Redis/Rails/integration
      # secrets, proxy vars, LD_* or Ruby/Bundler injection vars can reach the parser.
      # HOME/TMPDIR/XDG_CACHE_HOME are workspace-scoped so the parser cannot read or
      # write anything outside its private sandbox anyway.
      def child_env
        {
          'PATH' => CHILD_PATH,
          'LANG' => 'C',
          'LC_ALL' => 'C',
          'HOME' => @dir,
          'TMPDIR' => @tmpdir,
          'XDG_CACHE_HOME' => @xdg_cache
        }
      end

      # Creates the workspace-scoped TMPDIR/XDG cache directories the parser child
      # needs (fontconfig cache, scratch), group-accessible to the dropped
      # marine_sop user when a sandbox drop is active.
      def prepare_child_env_dirs
        @tmpdir = File.join(@dir, 'tmp')
        @xdg_cache = File.join(@dir, 'cache')
        FileUtils.mkdir_p([@tmpdir, @xdg_cache])
        return unless @sandbox

        [@tmpdir, @xdg_cache].each do |path|
          File.chown(nil, @sandbox[:gid], path)
          File.chmod(0o770, path)
        end
      end

      def capture(argv)
        stdin, stdout_io, stderr_io, wait_thr = Open3.popen3(child_env, *command(argv), spawn_options)
        stdin.close

        out = String.new(encoding: Encoding::BINARY)
        readers = [
          reader { bounded_read(stdout_io, out) },
          reader { drain(stderr_io) }
        ]

        wait_or_timeout!(wait_thr, [stdout_io, stderr_io], readers)

        # Residual group cleanup after normal completion (see sweep_residual_group).
        sweep_residual_group(wait_thr.pid)

        Result.new(stdout: out, ok: wait_thr.value.success?)
      rescue Errno::ENOENT, Errno::EACCES
        raise Marine::Documents::Errors::SopProcessingDependencyUnavailableError
      ensure
        close(stdout_io, stderr_io)
      end

      # Wraps argv so external commands run under the locked marine_sop account and
      # the fail-closed sandbox launcher whenever the sandbox contract is active:
      #   [su-exec, marine_sop, launcher, workspace, --, *argv]
      # Without a sandbox (test contract only) argv is executed directly.
      def command(argv)
        return argv unless @sandbox

        [@sandbox[:binary], @sandbox[:user], @sandbox[:launcher], @dir, '--', *argv]
      end

      def spawn_options
        options = {
          pgroup: true,
          rlimit_as: RLIMIT_AS_BYTES,
          rlimit_cpu: RLIMIT_CPU_SECONDS,
          rlimit_fsize: RLIMIT_FSIZE_BYTES,
          rlimit_core: 0,
          # Blocker 2: strip the ENTIRE inherited environment (child_env above is the
          # only source) and close every inherited fd except the stdio pipes.
          unsetenv_others: true,
          close_others: true
        }
        options[:rlimit_nproc] = RLIMIT_NPROC if defined?(Process::RLIMIT_NPROC)
        options
      end

      # Drain thread whose exceptions are never printed: bounded_read/drain already handle
      # the expected IOError on a closed pipe, and on a forced timeout stop the thread is
      # killed cleanly, so a raw thread exception report must never leak.
      def reader
        Thread.new do
          Thread.current.report_on_exception = false
          yield
        end
      end

      # When subprocesses drop to marine_sop, that user must be able to traverse the
      # private workspace and create render outputs inside it. We grant ONLY the
      # marine_sop group rwx on the directory (no access for anyone else). Without a
      # sandbox the workspace stays the 0700 mktmpdir default.
      def grant_workspace_access
        return unless @sandbox

        File.chown(nil, @sandbox[:gid], @dir)
        File.chmod(0o770, @dir)
      end

      # ONE absolute deadline governs BOTH the child waiter AND the pipe drains: if
      # the child does not exit, OR the readers do not finish, by it the whole group
      # is SIGKILLed, our pipe ends are closed (releasing any reader blocked on a
      # descendant copy), the waiter reaped, the readers joined, and the stable
      # timeout raised. Returns true when everything completed in time.
      def wait_or_timeout!(wait_thr, ios, readers)
        return true if wait_by_deadline(wait_thr) && join_by_deadline(readers)

        terminate(wait_thr.pid)
        close(*ios)
        reap(wait_thr)
        stop(readers)
        raise Marine::Documents::Errors::SopOcrTimeoutError
      end

      # Joins the Open3 waiter within the remaining absolute deadline. Returns true only
      # if the child actually exited in time.
      def wait_by_deadline(wait_thr)
        remaining = remaining_seconds
        return false unless remaining.positive?

        !wait_thr.join(remaining).nil?
      end

      # Joins BOTH drain threads within the remaining absolute deadline. Returns true only
      # if every reader finished; a descendant holding a pipe FD open makes this return
      # false at the deadline instead of blocking forever.
      def join_by_deadline(readers)
        readers.all? do |reader|
          remaining = remaining_seconds
          remaining.positive? && !reader.join(remaining).nil?
        end
      end

      # After SIGKILLing the group, reap the Open3 waiter thread (bounded by the grace)
      # so the killed leader leaves no zombie.
      def reap(wait_thr)
        wait_thr.join(TERMINATE_GRACE_SECONDS)
      end

      # Stop the drain threads: the SIGKILL and the closed local pipe ends unblock any
      # pending read, so the thread exits on its own; we join within the grace, then
      # force-kill and join any straggler so no reader thread is ever left running.
      def stop(threads)
        threads.each do |thread|
          thread.join(TERMINATE_GRACE_SECONDS)
          thread.kill if thread.alive?
        end
        threads.each(&:join)
      end

      # Fully drains the pipe (so the child never blocks) while storing at most
      # MAX_OUTPUT_BYTES of stdout.
      def bounded_read(io, buffer)
        while (chunk = io.read(READ_CHUNK_BYTES))
          space = MAX_OUTPUT_BYTES - buffer.bytesize
          buffer << chunk.byteslice(0, space) if space.positive?
        end
      rescue IOError
        nil
      end

      def drain(io)
        while io.read(READ_CHUNK_BYTES); end
      rescue IOError
        nil
      end

      def close(*ios)
        ios.each { |io| io.close if io && !io.closed? }
      end

      # SIGKILL the whole process group (negative pid). The child was made a group
      # leader via pgroup: true, so this reaches any grandchildren too. The Open3
      # waiter thread reaps the leader, preventing a zombie.
      def terminate(pid)
        Process.kill('-KILL', pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end

      # After the leader exited and both pipes drained, SIGKILL any residual member
      # of the leader's original process group. The group is identified by the
      # leader pid (pgroup: true made the child its own group leader), and an
      # empty group fails fast with ESRCH, so the no-residual case costs one
      # syscall and no latency.
      def sweep_residual_group(leader_pid)
        Process.kill('-KILL', leader_pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end

      # Opens the path with O_NOFOLLOW (ELOOP on a symlinked filename), fstat-verifies
      # the SAME fd is a REGULAR file, resolves the fd through /proc/self/fd to the
      # canonical target path requiring it to be strictly beneath the private
      # workspace, then yields the open fd to the caller for fchown/fchmod. The fd
      # is NEVER closed before the yield and always closes afterwards, and the path
      # is NEVER reopened after verification, so the yielded grant cannot race a
      # path swap. Raises the stable extraction error on any rejection. The path
      # is opened as a File so the SAME fd can be verified (fstat), granted, and
      # closed; Ruby File/IO has no fchown/fchmod instance methods, so the grant
      # is applied through libc (Fiddle) on that SAME open fd.
      def with_workspace_fd(path)
        file = File.open(path, File::RDONLY | O_NOFOLLOW)
        begin
          raise Marine::Documents::Errors::SopExtractionFailedError unless file.stat.file?

          canonical = File.realpath("/proc/self/fd/#{file.fileno}")
          unless File.expand_path(canonical).start_with?(File.expand_path(@dir) + File::SEPARATOR)
            raise Marine::Documents::Errors::SopExtractionFailedError
          end

          yield file
        ensure
          file.close
        end
      # ANY SystemCallError — open/fstat/realpath failures and the libc
      # fchown/fchmod raises alike, whether an Errno::* subclass or a raw
      # SystemCallError — maps to the stable extraction error, which carries
      # no path or raw message.
      rescue SystemCallError
        raise Marine::Documents::Errors::SopExtractionFailedError
      end

      # Ruby 3.4 removed IO#chown/IO#chmod (and File has no fchown/fchmod instance
      # methods), so the fd-backed grant issues fchown(2)/fchmod(2) through libc
      # (Fiddle) on the SAME open verified fd. A nil uid/gid becomes -1 (POSIX:
      # leave that field unchanged). Raises the underlying SystemCallError on
      # failure so the grant fails closed with the stable extraction error.
      def fchown_fd(file_descriptor, uid, gid)
        rc = libc_fn('fchown', 3).call(file_descriptor, uid ? Integer(uid) : -1, gid ? Integer(gid) : -1)
        raise SystemCallError.new(nil, Fiddle.last_error) unless rc.zero?
      end

      def fchmod_fd(file_descriptor, mode)
        rc = libc_fn('fchmod', 2).call(file_descriptor, Integer(mode))
        raise SystemCallError.new(nil, Fiddle.last_error) unless rc.zero?
      end

      def libc_fn(name, arity)
        Fiddle::Function.new(Fiddle::Handle.new(nil)[name], [Fiddle::TYPE_INT] * arity, Fiddle::TYPE_INT)
      end

      def remaining_seconds
        @deadline - monotonic_now
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
