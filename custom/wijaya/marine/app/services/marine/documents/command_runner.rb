# Safe external-command runner for SOP extraction/OCR (Commit 1C).
#
# SECURITY / ROBUSTNESS GUARANTEES
#   * argv is executed DIRECTLY (Open3 + process spawn) — never an interpolated
#     shell string, never `/bin/sh -c`. Filenames and page numbers are passed as
#     discrete argv elements, so shell metacharacters can never be interpreted.
#   * a single hard extraction/OCR deadline (default 120s) is shared across EVERY
#     command run through one runner instance (i.e. per DOCUMENT, not per page).
#   * a timed-out child's whole process GROUP is SIGKILLed; the Open3 waiter thread
#     reaps it so no zombie survives.
#   * stdout and stderr are drained CONCURRENTLY by separate threads so a child can
#     never deadlock on a full pipe; stored stdout is bounded, and stderr is drained
#     but NEVER captured/exposed.
#   * all temporary files live inside a single private 0700 directory that is always
#     removed in `ensure` (via `.open`).
#   * a missing binary maps to a stable dependency error; results/errors are stable
#     objects that leak no path, command line, or raw stderr.
require 'open3'
require 'tmpdir'
require 'fileutils'

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

      # Stable result. Deliberately exposes ONLY captured stdout and a success flag —
      # never stderr, the argv, or the exit signal details.
      Result = Struct.new(:stdout, :ok, keyword_init: true)

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
      end

      # Returns a unique path INSIDE the private workspace for a caller-controlled base
      # label. The label is sanitized and made unique, so it can never traverse out of
      # the workspace.
      def workspace_path(label)
        @seq += 1
        safe = label.to_s.gsub(/[^a-zA-Z0-9._-]/, '_')
        File.join(@dir, "#{safe}-#{@seq}")
      end

      # Runs argv to completion (or the shared deadline) and returns a Result.
      def run(*argv)
        argv = argv.map(&:to_s)
        raise Errors::SopExtractionFailedError if argv.empty?

        remaining = remaining_seconds
        raise Errors::SopOcrTimeoutError if remaining <= 0

        capture(argv, remaining)
      end

      def cleanup!
        FileUtils.remove_entry(@dir) if @dir && Dir.exist?(@dir)
      rescue StandardError
        nil
      end

      private

      def capture(argv, remaining)
        stdin, stdout_io, stderr_io, wait_thr = Open3.popen3(*argv, pgroup: true)
        stdin.close

        out = String.new(encoding: Encoding::BINARY)
        readers = [
          Thread.new { bounded_read(stdout_io, out) },
          Thread.new { drain(stderr_io) }
        ]

        if wait_thr.join(remaining).nil?
          terminate(wait_thr.pid)
          reap(wait_thr)
          stop(readers)
          raise Errors::SopOcrTimeoutError
        end

        readers.each(&:join)
        Result.new(stdout: out, ok: wait_thr.value.success?)
      rescue Errno::ENOENT, Errno::EACCES
        raise Errors::SopProcessingDependencyUnavailableError
      ensure
        [stdout_io, stderr_io].each { |io| io.close if io && !io.closed? }
      end

      # After SIGKILLing the group, reap the Open3 waiter thread (bounded by the grace)
      # so the killed leader leaves no zombie.
      def reap(wait_thr)
        wait_thr.join(TERMINATE_GRACE_SECONDS)
      end

      # Stop the drain threads: the SIGKILL closes the child's pipe ends, so a pending
      # read returns and the thread exits on its own; we join within the grace, then
      # force-kill and join any straggler so no reader thread is ever left running.
      def stop(threads)
        threads.each { |thread| thread.join(TERMINATE_GRACE_SECONDS) }
        threads.each { |thread| thread.kill if thread.alive? }
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
