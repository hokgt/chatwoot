# Safe external-command runner for SOP extraction/OCR (Commit 1C).
#
# SECURITY / ROBUSTNESS GUARANTEES
#   * argv is executed DIRECTLY (Open3 + process spawn) — never an interpolated
#     shell string, never `/bin/sh -c`. Filenames and page numbers are passed as
#     discrete argv elements, so shell metacharacters can never be interpreted.
#   * a single hard extraction/OCR deadline (default 120s) is shared across EVERY
#     command run through one runner instance (i.e. per DOCUMENT, not per page). The
#     SAME absolute deadline bounds BOTH the child waiter AND the two pipe drains, so a
#     descendant that keeps stdout/stderr open after the leader exits can never make a
#     drain join block past the deadline.
#   * a timed-out (or drain-blocked) child's whole process GROUP is SIGKILLed; the Open3
#     waiter thread reaps it so no zombie survives, and the local pipe ends are closed so
#     any reader still blocked on a descendant's copy is released.
#   * stdout and stderr are drained CONCURRENTLY by separate threads so a child can
#     never deadlock on a full pipe; stored stdout is bounded, and stderr is drained
#     but NEVER captured/exposed.
#   * every subprocess is spawned with conservative RLIMITs (address space, CPU, output
#     file size, core, process count) so a pathological input cannot exhaust host memory,
#     disk, or CPU even before the wall deadline fires.
#   * in a derived image that ships su-exec and a locked `marine_sop` account, every
#     external command runs UNDER that unprivileged user; in a plain base image (unit
#     tests) argv is executed directly. No user-controlled value is ever shell-expanded.
#   * all temporary files live inside a single private directory that is always removed
#     in `ensure` (via `.open`).
#   * a missing binary maps to a stable dependency error; results/errors are stable
#     objects that leak no path, command line, or raw stderr.
require 'open3'
require 'tmpdir'
require 'fileutils'
require 'etc'

module Marine
  module Documents
    class CommandRunner
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
      # a frozen descriptor { binary:, user:, uid:, gid: } or nil (run argv directly).
      def self.privilege_drop
        return @privilege_drop if defined?(@privilege_drop)

        @privilege_drop = compute_privilege_drop
      end

      def self.compute_privilege_drop
        return nil unless Process.uid.zero?

        binary = SU_EXEC_CANDIDATES.find { |candidate| File.executable?(candidate) }
        return nil unless binary

        pw = Etc.getpwnam(SOP_SUBPROCESS_USER)
        { binary: binary, user: SOP_SUBPROCESS_USER, uid: pw.uid, gid: pw.gid }.freeze
      rescue ArgumentError
        nil
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
        @deadline = monotonic_now + deadline_seconds
        @dir = Dir.mktmpdir('marine-sop')
        @seq = 0
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

      # Marks a workspace INPUT file readable by the dropped marine_sop subprocess user
      # (group read) so a privilege-dropped Poppler/Tesseract can open it. A no-op when
      # no privilege drop is active. Never touches anything outside the workspace.
      def grant_read(path)
        drop = self.class.privilege_drop
        return path unless drop

        File.chown(nil, drop[:gid], path)
        File.chmod(0o640, path)
        path
      end

      # Runs argv to completion (or the shared deadline) and returns a Result.
      def run(*argv)
        argv = argv.map(&:to_s)
        raise Errors::SopExtractionFailedError if argv.empty?
        raise Errors::SopOcrTimeoutError if remaining_seconds <= 0

        capture(argv)
      end

      def cleanup!
        FileUtils.remove_entry(@dir) if @dir && Dir.exist?(@dir)
      rescue StandardError
        nil
      end

      private

      def capture(argv)
        stdin, stdout_io, stderr_io, wait_thr = Open3.popen3(*command(argv), spawn_options)
        stdin.close

        out = String.new(encoding: Encoding::BINARY)
        readers = [
          reader { bounded_read(stdout_io, out) },
          reader { drain(stderr_io) }
        ]

        # ONE absolute deadline governs BOTH the child waiter AND the pipe drains. A
        # leader can exit while a descendant keeps stdout/stderr open, which would leave
        # the reader joins blocked indefinitely; if the child does not exit, OR the
        # readers do not finish, by the deadline we SIGKILL the whole group, close our
        # pipe ends (releasing any reader blocked on a descendant's copy), reap the
        # waiter, join the readers and raise the stable timeout.
        unless wait_by_deadline(wait_thr) && join_by_deadline(readers)
          terminate(wait_thr.pid)
          close(stdout_io, stderr_io)
          reap(wait_thr)
          stop(readers)
          raise Errors::SopOcrTimeoutError
        end

        Result.new(stdout: out, ok: wait_thr.value.success?)
      rescue Errno::ENOENT, Errno::EACCES
        raise Errors::SopProcessingDependencyUnavailableError
      ensure
        close(stdout_io, stderr_io)
      end

      # Wraps argv so external commands run under the locked marine_sop account whenever a
      # privilege drop is available; otherwise argv is executed directly.
      def command(argv)
        drop = self.class.privilege_drop
        drop ? [drop[:binary], drop[:user], *argv] : argv
      end

      def spawn_options
        options = {
          pgroup: true,
          rlimit_as: RLIMIT_AS_BYTES,
          rlimit_cpu: RLIMIT_CPU_SECONDS,
          rlimit_fsize: RLIMIT_FSIZE_BYTES,
          rlimit_core: 0
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
      # privilege drop the workspace stays the 0700 mktmpdir default.
      def grant_workspace_access
        drop = self.class.privilege_drop
        return unless drop

        File.chown(nil, drop[:gid], @dir)
        File.chmod(0o770, @dir)
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

      def remaining_seconds
        @deadline - monotonic_now
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
