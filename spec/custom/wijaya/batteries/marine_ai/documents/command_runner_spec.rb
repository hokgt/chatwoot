# frozen_string_literal: true

require 'rails_helper'

# Exercises the REAL subprocess behavior of the safe command runner using only tiny
# POSIX utilities present in the base test image (cat, head, sleep, yes). No shell is
# ever involved.
RSpec.describe Marine::Documents::CommandRunner do
  around do |example|
    Dir.mktmpdir do |dir|
      @tmp = dir
      example.run
    end
  end

  it 'executes argv directly and never through a shell (no interpolation)' do
    marker = File.join(@tmp, 'pwned')
    # If argv were shell-interpolated, this would create the marker file. Passed as a
    # single literal argument, `cat` just fails to open a file with that odd name.
    result = described_class.open { |r| r.run('cat', "nope; touch #{marker}") }

    expect(result.ok).to be(false)
    expect(File.exist?(marker)).to be(false)
  end

  it 'returns the exact literal bytes of an argument-referenced file (content not executed)' do
    payload = "; rm -rf / && echo danger\n".b
    file = File.join(@tmp, 'payload.txt')
    File.binwrite(file, payload)

    result = described_class.open { |r| r.run('cat', file) }

    expect(result.ok).to be(true)
    expect(result.stdout).to eq(payload)
  end

  it 'bounds captured stdout to MAX_OUTPUT_BYTES while still draining the pipe' do
    stub_const('Marine::Documents::CommandRunner::MAX_OUTPUT_BYTES', 100)
    big = File.join(@tmp, 'big.txt')
    File.binwrite(big, 'a' * 5000)

    result = described_class.open { |r| r.run('cat', big) }

    expect(result.ok).to be(true)
    expect(result.stdout.bytesize).to eq(100)
  end

  it 'caps captured stdout at a defensible 1 MiB by default' do
    expect(described_class::MAX_OUTPUT_BYTES).to eq(1 * 1024 * 1024)
  end

  it 'enforces the shared deadline and kills a timed-out child promptly, leaving no live threads' do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    before = Thread.list.size

    expect do
      described_class.open(deadline_seconds: 1) { |r| r.run('sleep', '30') }
    end.to raise_error(Marine::Documents::Errors::SopOcrTimeoutError)

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    expect(elapsed).to be < 10
    # The waiter is reaped and both drain threads are joined, so no runner thread leaks.
    expect(Thread.list.size).to be <= before
  end

  it 'maps a missing binary to the stable dependency error' do
    expect do
      described_class.open { |r| r.run('marine-nonexistent-binary-xyz') }
    end.to raise_error(Marine::Documents::Errors::SopProcessingDependencyUnavailableError)
  end

  it 'never exposes raw stderr on the result' do
    result = described_class.open { |r| r.run('cat', File.join(@tmp, 'does-not-exist')) }

    expect(result.ok).to be(false)
    expect(described_class::Result.members).to eq(%i[stdout ok])
    expect(result).not_to respond_to(:stderr)
  end

  it 'creates a private 0700 workspace and always removes it afterwards' do
    captured = nil
    described_class.open do |r|
      captured = r.dir
      expect(Dir.exist?(captured)).to be(true)
      expect(File.stat(captured).mode & 0o777).to eq(0o700)
    end
    expect(Dir.exist?(captured)).to be(false)
  end

  it 'removes the workspace even when the block raises' do
    captured = nil
    expect do
      described_class.open do |r|
        captured = r.dir
        raise 'boom'
      end
    end.to raise_error('boom')
    expect(Dir.exist?(captured)).to be(false)
  end

  it 'enforces the deadline even when a descendant holds the stdout pipe open after the leader exits' do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    before = Thread.list.size

    expect do
      # The leader (sh) exits 0 immediately, but the backgrounded `sleep` inherits and
      # keeps the stdout pipe write-end open. A naive drain join would block forever; the
      # shared absolute deadline must bound the drain and SIGKILL the whole group.
      described_class.open(deadline_seconds: 1) { |r| r.run('sh', '-c', 'sleep 30 & exit 0') }
    end.to raise_error(Marine::Documents::Errors::SopOcrTimeoutError)

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    expect(elapsed).to be < 10
    # The group SIGKILL releases the descendant, the pipe ends are closed, and both drain
    # threads are joined, so no runner thread leaks even on this drain-blocked path.
    expect(Thread.list.size).to be <= before
  end

  it 'drains a large stderr concurrently without deadlocking and never captures it' do
    # ~160 KiB of stderr (far past a single pipe buffer) while emitting a little stdout.
    # Without a SEPARATE concurrent stderr drain the child would block writing stderr while
    # we only read stdout -> deadlock. stderr is drained but must never appear in the result.
    script = 'i=0; while [ $i -lt 20000 ]; do echo errline 1>&2; i=$((i+1)); done; echo done'

    result = described_class.open(deadline_seconds: 30) { |r| r.run('sh', '-c', script) }

    expect(result.ok).to be(true)
    expect(result.stdout).to eq("done\n")
  end

  describe 'subprocess CPU rlimit (multi-thread aware backstop)' do
    it 'defines a separate CPU-seconds budget larger than the wall deadline' do
      expect(described_class::RLIMIT_CPU_SECONDS).to eq(480)
      expect(described_class::RLIMIT_CPU_SECONDS).to be > described_class::GLOBAL_DEADLINE_SECONDS
    end

    it 'spawns with the CPU-seconds backstop, not the wall deadline, and keeps the other rlimits' do
      options = described_class.allocate.send(:spawn_options)

      expect(options[:rlimit_cpu]).to eq(described_class::RLIMIT_CPU_SECONDS)
      expect(options[:rlimit_cpu]).not_to eq(described_class::GLOBAL_DEADLINE_SECONDS)
      expect(options[:rlimit_as]).to eq(1 * 1024 * 1024 * 1024)
      expect(options[:rlimit_fsize]).to eq(64 * 1024 * 1024)
      expect(options[:rlimit_core]).to eq(0)
      expect(options[:rlimit_nproc]).to eq(256) if defined?(Process::RLIMIT_NPROC)
    end
  end

  describe 'subprocess privilege drop (resource isolation)' do
    it 'runs argv directly (no privilege drop) when the process is not root' do
      allow(Process).to receive(:uid).and_return(1000)
      expect(described_class.compute_privilege_drop).to be_nil
    end

    it 'falls back to direct exec when root but su-exec is absent' do
      allow(Process).to receive(:uid).and_return(0)
      allow(File).to receive(:executable?).and_return(false)
      expect(described_class.compute_privilege_drop).to be_nil
    end

    it 'falls back to direct exec when root and su-exec present but the marine_sop account is missing' do
      allow(Process).to receive(:uid).and_return(0)
      allow(File).to receive(:executable?).and_return(true)
      allow(Etc).to receive(:getpwnam).and_raise(ArgumentError)
      expect(described_class.compute_privilege_drop).to be_nil
    end

    it 'wraps argv under su-exec + the locked user when a privilege drop is active' do
      drop = { binary: '/sbin/su-exec', user: 'marine_sop', uid: 100, gid: 101 }.freeze
      allow(described_class).to receive(:privilege_drop).and_return(drop)

      wrapped = described_class.allocate.send(:command, %w[tesseract in stdout -l ind+eng])

      expect(wrapped).to eq(['/sbin/su-exec', 'marine_sop', 'tesseract', 'in', 'stdout', '-l', 'ind+eng'])
    end

    it 'executes argv unchanged when no privilege drop is active' do
      allow(described_class).to receive(:privilege_drop).and_return(nil)

      expect(described_class.allocate.send(:command, %w[pdfinfo file])).to eq(%w[pdfinfo file])
    end
  end
end
