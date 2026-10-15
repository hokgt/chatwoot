# frozen_string_literal: true

require 'rails_helper'
require 'open3'
require 'rbconfig'

# Exercises the REAL subprocess behavior of the safe command runner using only tiny
# POSIX utilities present in the base test image (cat, head, sleep, yes, env). No
# shell is ever involved.
#
# The whole file runs under the explicit safe test contract
# (MARINE_SOP_SANDBOX_TEST_ONLY=1 + Rails test env): without it the runner would
# fail closed on the missing sandbox launcher in the plain test image. The
# fail-closed identity itself is covered by dedicated sandbox describes below.
RSpec.describe Marine::Documents::CommandRunner do
  around do |example|
    ENV['MARINE_SOP_SANDBOX_TEST_ONLY'] = '1'
    example.run
  ensure
    ENV.delete('MARINE_SOP_SANDBOX_TEST_ONLY')
  end

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

  it 'cleans residual group members after the leader exits (no orphans, no latency when none)' do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # The leader spawns a background descendant that redirects BOTH pipes away (it
    # holds no pipe fd), prints its pid, and exits 0 immediately — so the drain
    # joins complete and the leader completes normally. The runner must return
    # promptly AND sweep the residual group member so nothing from this run
    # outlives it (previously the orphaned `sleep 30` survived the document run).
    result = described_class.open { |r| r.run('sh', '-c', 'sleep 30 >/dev/null 2>&1 & echo $!') }

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    expect(result.ok).to be(true)
    expect(elapsed).to be < 10
    pid = result.stdout.strip.to_i
    expect(pid).to be > 1

    # The residual descendant must be SIGKILLed by the group sweep: gone, or (if
    # init has not reaped it yet) at most a zombie awaiting reap — never alive.
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    loop do
      state = proc_state(pid)
      break if state.nil? || state == 'Z'
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.1
    end
    expect(proc_state(pid)).to be_nil.or eq('Z')
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

  describe 'child environment scrub (Blocker 2)' do
    it 'declares the exact fixed env key allowlist' do
      expect(described_class::CHILD_ENV_KEYS)
        .to eq(%w[HOME LANG LC_ALL PATH TMPDIR XDG_CACHE_HOME])
    end

    it 'spawns with unsetenv_others and close_others so no inherited env or fd can leak' do
      options = described_class.allocate.send(:spawn_options)

      expect(options[:unsetenv_others]).to be(true)
      expect(options[:close_others]).to be(true)
      # The hardening is additive: every pre-existing limit is still in force.
      expect(options[:pgroup]).to be(true)
      expect(options[:rlimit_as]).to eq(1 * 1024 * 1024 * 1024)
    end

    it 'delivers exactly the allowlisted env to the child — no inherited secrets, no LD_*/DB/Rails vars' do
      ENV['WIJAYA_SECRET_CANARY'] = 'definitely-a-secret'
      ENV['WIJAYA_LD_CANARY'] = '/tmp/evil.so'
      ENV['WIJAYA_DBURL_CANARY'] = 'postgres://secret'

      result = described_class.open { |r| r.run('env') }

      keys = result.stdout.lines.map { |line| line.split('=', 2).first.strip }.sort
      expect(keys).to eq(described_class::CHILD_ENV_KEYS.sort)
      expect(result.stdout).not_to include('definitely-a-secret')
      expect(result.stdout).not_to include('/tmp/evil.so')
      expect(result.stdout).not_to include('postgres://secret')
      expect(result.stdout).to include("LC_ALL=C\n")
      expect(result.stdout).to include("PATH=#{described_class::CHILD_PATH}\n")
    ensure
      ENV.delete('WIJAYA_SECRET_CANARY')
      ENV.delete('WIJAYA_LD_CANARY')
      ENV.delete('WIJAYA_DBURL_CANARY')
    end

    it 'scopes HOME/TMPDIR/XDG_CACHE_HOME inside the private workspace and creates them' do
      described_class.open do |r|
        env = described_class.allocate
        env.instance_variable_set(:@dir, r.dir)
        env.instance_variable_set(:@tmpdir, File.join(r.dir, 'tmp'))
        env.instance_variable_set(:@xdg_cache, File.join(r.dir, 'cache'))
        expect(env.send(:child_env)['HOME']).to eq(r.dir)
        expect(env.send(:child_env)['TMPDIR']).to eq(File.join(r.dir, 'tmp'))
        expect(env.send(:child_env)['XDG_CACHE_HOME']).to eq(File.join(r.dir, 'cache'))
        expect(Dir.exist?(File.join(r.dir, 'tmp'))).to be(true)
        expect(Dir.exist?(File.join(r.dir, 'cache'))).to be(true)
      end
    end

    it 'never places the workspace outside a single private root (labels cannot traverse out)' do
      described_class.open do |r|
        escaped = r.workspace_path('../../../../etc/passwd')
        expect(File.expand_path(escaped)).to start_with(File.expand_path(r.dir) + File::SEPARATOR)
      end
    end
  end

  describe 'subprocess privilege drop (resource isolation)' do
    it 'runs argv directly (no privilege drop) when the process is not root' do
      allow(Process).to receive(:uid).and_return(1000)
      expect(described_class.compute_privilege_drop).to be_nil
    end

    it 'cannot drop when root but su-exec is absent' do
      allow(Process).to receive(:uid).and_return(0)
      allow(File).to receive(:executable?).and_return(false)
      expect(described_class.compute_privilege_drop).to be_nil
    end

    it 'cannot drop when root and su-exec present but the marine_sop account is missing' do
      allow(Process).to receive(:uid).and_return(0)
      allow(File).to receive(:executable?).and_return(true)
      allow(Etc).to receive(:getpwnam).and_raise(ArgumentError)
      expect(described_class.compute_privilege_drop).to be_nil
    end
  end

  def proc_state(pid)
    File.read("/proc/#{pid}/stat").split(') ', 2)[1].to_s.split.first
  rescue StandardError
    nil
  end

  describe 'grant_read input hardening (Blocker 2)' do
    let(:sandbox) do
      { binary: '/sbin/su-exec', user: 'marine_sop', uid: 100, gid: 101,
        launcher: '/usr/local/bin/wijaya-sop-sandbox' }.freeze
    end

    def sandboxed_runner(dir)
      runner = described_class.allocate
      runner.instance_variable_set(:@sandbox, sandbox)
      runner.instance_variable_set(:@dir, dir)
      runner
    end

    it 'fchown/fchmods the SAME verified fd (never a path reopened after verify)' do
      Dir.mktmpdir do |dir|
        file = File.join(dir, 'input.pdf')
        File.binwrite(file, 'x')

        # Guard regression: any path-based metadata change (a reopen after
        # verification) must never be reached.
        allow(File).to receive(:chown) { raise 'path-based File.chown called' }
        allow(File).to receive(:chmod) { raise 'path-based File.chmod called' }

        expect(sandboxed_runner(dir).grant_read(file)).to eq(file)

        # The grant was applied to the open verified fd: the on-disk metadata
        # reflects the fchown/fchmod with no path-based call ever happening.
        st = File.stat(file)
        expect(st.gid).to eq(101)
        expect(st.mode & 0o7777).to eq(0o640)
      end
    end

    it 'rejects a symlinked filename inside the workspace (O_NOFOLLOW)' do
      Dir.mktmpdir do |dir|
        target = File.join(dir, 'real.bin')
        File.binwrite(target, 'x')
        link = File.join(dir, 'link.bin')
        File.symlink(target, link)

        expect { sandboxed_runner(dir).grant_read(link) }
          .to raise_error(Marine::Documents::Errors::SopExtractionFailedError)
      end
    end

    it 'rejects a non-regular file (directory) inside the workspace' do
      Dir.mktmpdir do |dir|
        subdir = File.join(dir, 'sub')
        Dir.mkdir(subdir)

        expect { sandboxed_runner(dir).grant_read(subdir) }
          .to raise_error(Marine::Documents::Errors::SopExtractionFailedError)
      end
    end

    it 'rejects a regular file whose canonical fd target is outside the workspace' do
      Dir.mktmpdir do |other|
        Dir.mktmpdir do |dir|
          outside = File.join(other, 'outside.bin')
          File.binwrite(outside, 'x')

          expect { sandboxed_runner(dir).grant_read(outside) }
            .to raise_error(Marine::Documents::Errors::SopExtractionFailedError)
        end
      end
    end

    it 'rejects an intermediate symlink escape that resolves outside the workspace' do
      Dir.mktmpdir do |other|
        Dir.mktmpdir do |dir|
          outside = File.join(other, 'outside.bin')
          File.binwrite(outside, 'x')
          File.symlink(other, File.join(dir, 'escape-dir'))
          path = File.join(dir, 'escape-dir', 'outside.bin')

          expect { sandboxed_runner(dir).grant_read(path) }
            .to raise_error(Marine::Documents::Errors::SopExtractionFailedError)
        end
      end
    end

    it 'is a no-op without a sandbox (test contract only)' do
      runner = described_class.allocate
      runner.instance_variable_set(:@sandbox, nil)
      runner.instance_variable_set(:@dir, '/tmp/anything')

      expect(runner.grant_read('/tmp/anything/in.pdf')).to eq('/tmp/anything/in.pdf')
    end
  end

  describe 'sandbox fail-closed identity (Blocker 2)' do
    before { described_class.instance_variable_set(:@sandbox, nil) }

    it 'raises the stable dependency error when no privilege drop is available (non-root)' do
      allow(described_class).to receive(:test_contract?).and_return(false)
      allow(described_class).to receive(:compute_privilege_drop).and_return(nil)
      expect { described_class.sandbox }
        .to raise_error(Marine::Documents::Errors::SopProcessingDependencyUnavailableError)
    end

    it 'raises when the privilege drop exists but the sandbox launcher is missing (no fallback to su-exec-only)' do
      allow(described_class).to receive(:test_contract?).and_return(false)
      allow(described_class).to receive(:compute_privilege_drop)
        .and_return({ binary: '/sbin/su-exec', user: 'marine_sop', uid: 100, gid: 101 }.freeze)
      allow(File).to receive(:executable?).and_call_original
      allow(File).to receive(:executable?).with(described_class::SANDBOX_LAUNCHER).and_return(false)

      expect { described_class.sandbox }
        .to raise_error(Marine::Documents::Errors::SopProcessingDependencyUnavailableError)
    end

    it 'raises the stable dependency error when an allowlisted parser binary is missing' do
      allow(described_class).to receive(:test_contract?).and_return(false)
      allow(described_class).to receive(:compute_privilege_drop)
        .and_return({ binary: '/sbin/su-exec', user: 'marine_sop', uid: 100, gid: 101 }.freeze)
      allow(File).to receive(:executable?).and_call_original
      allow(File).to receive(:executable?).with(described_class::SANDBOX_LAUNCHER).and_return(true)
      described_class::ALLOWED_EXECUTABLES.each_value do |path|
        allow(File).to receive(:executable?).with(path).and_return(true)
      end
      allow(File).to receive(:executable?)
        .with(described_class::ALLOWED_EXECUTABLES['tesseract']).and_return(false)

      expect { described_class.sandbox }
        .to raise_error(Marine::Documents::Errors::SopProcessingDependencyUnavailableError)
    end

    it 'returns the full launcher descriptor when every component is present' do
      allow(described_class).to receive(:compute_privilege_drop)
        .and_return({ binary: '/sbin/su-exec', user: 'marine_sop', uid: 100, gid: 101 }.freeze)
      allow(File).to receive(:executable?).and_call_original
      allow(File).to receive(:executable?).with(described_class::SANDBOX_LAUNCHER).and_return(true)
      described_class::ALLOWED_EXECUTABLES.each_value do |path|
        allow(File).to receive(:executable?).with(path).and_return(true)
      end

      expect(described_class.sandbox).to eq(
        { binary: '/sbin/su-exec', user: 'marine_sop', uid: 100, gid: 101,
          launcher: '/usr/local/bin/wijaya-sop-sandbox' }
      )
    end

    it 'never falls back to unsandboxed execution when the contract is unavailable' do
      allow(described_class).to receive(:sandbox)
        .and_raise(Marine::Documents::Errors::SopProcessingDependencyUnavailableError)

      expect { described_class.open { |r| r.run('pdfinfo', '/tmp/none.pdf') } }
        .to raise_error(Marine::Documents::Errors::SopProcessingDependencyUnavailableError)
    end

    it 'keeps test-only unsandboxed execution behind the explicit safe test contract' do
      allow(described_class).to receive(:test_contract?).and_return(true)
      allow(described_class).to receive(:compute_privilege_drop).and_return(nil)
      expect(described_class.sandbox).to be_nil
      expect(described_class.sandbox_available?).to be(false)
    end

    it 'reports an unavailable contract as false, never as an exception, from the probe' do
      allow(described_class).to receive(:sandbox)
        .and_raise(Marine::Documents::Errors::SopProcessingDependencyUnavailableError)
      expect(described_class.sandbox_available?).to be(false)
    end
  end

  describe 'sandbox command construction (Blocker 2)' do
    let(:sandbox) do
      { binary: '/sbin/su-exec', user: 'marine_sop', uid: 100, gid: 101,
        launcher: '/usr/local/bin/wijaya-sop-sandbox' }.freeze
    end

    def bare_runner
      runner = described_class.allocate
      runner.instance_variable_set(:@sandbox, sandbox)
      runner.instance_variable_set(:@dir, '/tmp/ws')
      runner
    end

    it 'wraps argv under su-exec + the launcher + the private workspace' do
      wrapped = bare_runner.send(:command, %w[/usr/bin/pdfinfo /tmp/ws/doc.pdf])

      expect(wrapped).to eq(
        ['/sbin/su-exec', 'marine_sop', '/usr/local/bin/wijaya-sop-sandbox', '/tmp/ws', '--',
         '/usr/bin/pdfinfo', '/tmp/ws/doc.pdf']
      )
    end

    it 'resolves allowlisted parser names to absolute paths' do
      resolved = bare_runner.send(:resolve_executable, %w[tesseract /tmp/ws/in stdout -l ind+eng])

      expect(resolved).to eq(%w[/usr/bin/tesseract /tmp/ws/in stdout -l ind+eng])
    end

    it 'accepts the exact absolute allowlisted path' do
      resolved = bare_runner.send(:resolve_executable, %w[/usr/bin/pdftoppm -png /tmp/in])

      expect(resolved).to eq(%w[/usr/bin/pdftoppm -png /tmp/in])
    end

    it 'refuses non-allowlisted executables with the stable extraction error' do
      expect { bare_runner.send(:resolve_executable, %w[curl http://example.test]) }
        .to raise_error(Marine::Documents::Errors::SopExtractionFailedError)
      expect { bare_runner.send(:resolve_executable, %w[/bin/sh -c x]) }
        .to raise_error(Marine::Documents::Errors::SopExtractionFailedError)
    end

    it 'passes argv through untouched without a sandbox (test contract only)' do
      runner = described_class.allocate
      runner.instance_variable_set(:@sandbox, nil)

      expect(runner.send(:command, %w[cat file])).to eq(%w[cat file])
      expect(runner.send(:resolve_executable, %w[cat file])).to eq(%w[cat file])
    end
  end

  describe 'launcher contract cross-check (Blocker 2)' do
    let(:launcher_source) do
      File.read(Rails.root.join('custom/wijaya/batteries/marine_ai/deploy/wijaya_sop_sandbox.c'))
    end

    it 'the C launcher allowlists exactly the Ruby executables (plus the musl loader)' do
      c_exec = launcher_source[/EXECUTE_PATHS\[\][^;]*?\{([^}]*)\}/m, 1].to_s.scan(/"([^"]+)"/).flatten

      expect(c_exec)
        .to contain_exactly(*described_class::ALLOWED_EXECUTABLES.values, '/lib/ld-musl-x86_64.so.1')
    end

    it 'the C launcher allowlists exactly the Ruby child env keys' do
      c_env = launcher_source[/ENV_ALLOWLIST\[\][^;]*?\{([^}]*)\}/m, 1].to_s.scan(/"([^"]+)"/).flatten

      expect(c_env).to match_array(described_class::CHILD_ENV_KEYS)
    end

    it 'the C exec-mode target allowlist is exactly the four Ruby parsers (never the loader)' do
      c_exec_mode = launcher_source[/EXEC_MODE_ALLOWLIST\[\][^;]*?\{([^}]*)\}/m, 1].to_s.scan(/"([^"]+)"/).flatten

      expect(c_exec_mode).to match_array(described_class::ALLOWED_EXECUTABLES.values)
    end

    it 'the C read-only trees carry the real Alpine tessdata path and no broad /usr/bin read' do
      c_ro = launcher_source[/READ_ONLY_PATHS\[\][^;]*?\{([^}]*)\}/m, 1].to_s.scan(/"([^"]+)"/).flatten

      expect(c_ro).to include('/usr/lib', '/lib', '/etc/fonts', '/usr/share/fonts')
      expect(c_ro).not_to include('/etc')
      expect(c_ro).to include('/usr/share/tessdata')
      expect(c_ro).not_to include('/usr/bin')
      expect(c_ro).not_to include('/usr/share/tesseract-ocr')
    end

    it 'the launcher denies sockets, io_uring and process escapes, and is fail-closed (static markers)' do
      expect(launcher_source).to include('__NR_socket')
      expect(launcher_source).to include('__NR_socketpair')
      expect(launcher_source).to include('__NR_io_uring_setup')
      expect(launcher_source).to include('__NR_io_uring_enter')
      expect(launcher_source).to include('__NR_io_uring_register')
      expect(launcher_source).to include('__NR_setsid')
      expect(launcher_source).to include('__NR_setpgid')
      expect(launcher_source).to include('__NR_capget')
      expect(launcher_source).to include('die_policy')
      expect(launcher_source).not_to include('SANDBOX_TEST')
    end

    it 'fail-closes on any nonzero effective/permitted capability (direct capget, no /proc)' do
      expect(launcher_source).to include('require_zero_capabilities')
      expect(launcher_source).to include('WIJAYA_CAP_VERSION_3')
      # Exactly two call sites — selftest mode and exec mode — both before any
      # policy is applied or exec performed, so the gate's su-exec'd selftest
      # exercises the zero-capability contract on every run.
      expect(launcher_source.scan('require_zero_capabilities();').length).to eq(2)
    end
  end

  describe 'explicit Fiddle dependency (final independent review)' do
    let(:runner_source) do
      File.read(Rails.root.join('custom/wijaya/batteries/marine_ai/app/services/marine/documents/command_runner.rb'))
    end

    it 'requires fiddle beside the other stdlib requires (never relies on Reline loading it)' do
      expect(runner_source).to include("require 'fiddle'")
    end

    it 'loads standalone in a fresh Ruby process and provides Fiddle::Function itself' do
      runner_path = Rails.root.join('custom/wijaya/batteries/marine_ai/app/services/marine/documents/command_runner.rb')
      script = <<~RUBY
        abort 'isolation: reline/irb must not be preloaded' unless $LOADED_FEATURES.grep(/reline|irb/).empty?
        load #{runner_path.to_s.inspect}
        abort 'isolation: Fiddle::Function unavailable after load' unless defined?(Fiddle::Function)
        Marine::Documents::CommandRunner.instance_method(:fchown_fd)
        Marine::Documents::CommandRunner.instance_method(:fchmod_fd)
        puts 'WIJAYA_FIDDLE_ISOLATION:OK'
      RUBY

      out, status = Open3.capture2(RbConfig.ruby, '-e', script)

      expect(status.success?).to be(true)
      expect(out).to include('WIJAYA_FIDDLE_ISOLATION:OK')
    end

    it 'keeps the fd-backed fchown/fchmod grant helpers available (direct constant availability)' do
      expect(defined?(Fiddle::Function)).to be_truthy
      expect(described_class.private_method_defined?(:libc_fn)).to be(true)
      expect(described_class.private_method_defined?(:fchown_fd)).to be(true)
      expect(described_class.private_method_defined?(:fchmod_fd)).to be(true)
    end
  end
end
