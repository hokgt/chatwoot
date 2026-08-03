# frozen_string_literal: true

require 'rails_helper'

# Exercises the REAL subprocess behavior of the safe command runner using only tiny
# POSIX utilities present in the base test image (cat, head, sleep, yes). No shell is
# ever involved.
RSpec.describe Marine::Documents::CommandRunner do
  around do |example|
    Dir.mktmpdir { |dir| @tmp = dir; example.run }
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
end
