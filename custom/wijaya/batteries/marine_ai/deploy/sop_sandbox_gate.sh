#!/bin/sh
# ============================================================================
# Marine SOP sandbox runtime gate (Blocker 2).
#
# Executed INSIDE the running marine_sop_worker container by the canonical deploy
# entrypoint (custom/wijaya/deploy/deploy.sh):
#
#   docker exec -i <marine_sop_worker-container> sh -s \
#     < custom/wijaya/batteries/marine_ai/deploy/sop_sandbox_gate.sh
#
# It must run as root (docker exec default) so it can plant SYNTHETIC canaries
# (randomized exclusive mktemp names) under /app/storage, /app/config and /tmp;
# cleanup removes EXACTLY the created paths and nothing else.
# No secrets, customer data, paths, argv or env values are ever printed: the only
# output lines are the fixed WIJAYA_SOP_GATE:* verdicts below.
#
# Proves, against the REAL derivative image and the REAL kernel:
#   1. every sandbox component exists (launcher, su-exec, marine_sop user, the four
#      allowlisted parser binaries);
#   2. the launcher self-test passes with a clean allowlisted env: workspace R/W,
#      decoys under /app/storage + /app/config + unrelated /tmp are unreadable,
#      a workspace symlink escape is unreadable, /app and /proc are unreadable,
#      a real /usr/bin file is unreadable (there is NO general /usr/bin read
#      access — only the four exact parser read+execute rules exist),
#      /bin/sh cannot be executed, no socket/socketpair can be created (so no
#      Internet, DNS, loopback, Docker network, Postgres/Redis, or Unix sockets);
#   3. the launcher FAILS CLOSED when a non-allowlisted env key is present, and
#      exec mode refuses every target that is not EXACTLY one of the four
#      allowlisted parsers (the musl loader included);
#   4. the real pdfinfo / pdftotext / pdftoppm / tesseract (ind+eng) all succeed
#      end-to-end through su-exec + the sandbox on a synthetic one-page PDF;
#   5. the parent's capability contract over the privilege-dropped child: the
#      launcher selftest runs through su-exec, so its internal capget check
#      (fail-closed unless the launcher process itself has ZERO effective and
#      permitted capabilities) is exercised on every gate run, and the gate
#      process — running as root INSIDE the worker container, so with the
#      container's exact cap_drop ALL + cap_add CHOWN/SETUID/SETGID/KILL set —
#      additionally proves it can SIGKILL a real su-exec-dropped marine_sop
#      process group (the CAP_KILL CommandRunner's deadline reaper needs).
#
# Success emits exactly: WIJAYA_SOP_GATE:PASS
# Any failure emits WIJAYA_SOP_GATE:FAIL:<token> and exits nonzero (after cleanup).
# ============================================================================
set -eu

LAUNCHER=/usr/local/bin/wijaya-sop-sandbox
SENTINEL=WIJAYA_SOP_GATE
STORAGE_CANARY=
CONFIG_CANARY=
TMP_CANARY=
WS=

cleanup() {
  rm -f "$STORAGE_CANARY" "$CONFIG_CANARY" "$TMP_CANARY" 2>/dev/null || :
  if [ -n "$WS" ]; then su-exec marine_sop rm -rf "$WS" 2>/dev/null || :; fi
}
trap cleanup EXIT INT TERM

fail() { echo "$SENTINEL:FAIL:$1"; exit 1; }

# --- 1) components ---------------------------------------------------------
[ -x "$LAUNCHER" ] || fail launcher
command -v su-exec >/dev/null 2>&1 || fail su-exec
# Absolute path: the env -i invocations below run with an allowlisted
# PATH=/usr/bin:/bin (the contract the CommandRunner enforces), which does
# NOT contain su-exec (it lives in /sbin) — so every allowlisted-env
# su-exec invocation must use the resolved absolute path.
SU_EXEC="$(command -v su-exec)"
id marine_sop >/dev/null 2>&1 || fail user
for b in /usr/bin/pdfinfo /usr/bin/pdftotext /usr/bin/pdftoppm /usr/bin/tesseract; do
  [ -x "$b" ] || fail parser
done

# --- 2) synthetic canaries + marine_sop-owned workspace -------------------
# The workspace is created AS marine_sop so the dropped parser can write into it,
# exactly like a real CommandRunner workspace.
WS="$(su-exec marine_sop mktemp -d /tmp/wijaya-sop-gate.XXXXXXXX)"
su-exec marine_sop mkdir -p "$WS/tmp" "$WS/cache"
# Randomized, exclusively-created (mktemp = O_EXCL) canaries: no fixed
# predictable name, so nothing can pre-create or race the canary paths, and the
# cleanup trap removes EXACTLY these created paths (the vars below), never a
# fixed shared path another process might legitimately own.
STORAGE_CANARY="$(mktemp /app/storage/.wijaya-sop-gate-canary.XXXXXXXX)"
CONFIG_CANARY="$(mktemp /app/config/.wijaya-sop-gate-canary.XXXXXXXX)"
TMP_CANARY="$(mktemp /tmp/.wijaya-sop-gate-canary.XXXXXXXX)"
# The workspace is owned by marine_sop with mode 0700 (mktemp default) and
# the gate process runs as root with NO CAP_DAC_OVERRIDE (cap_drop ALL), so
# every write into the workspace — including this escape probe symlink and
# the synthetic PDF below — MUST go through su-exec marine_sop, exactly like
# the drops it is probing; root-by DAC override would bypass the contract.
su-exec marine_sop ln -sfn "$CONFIG_CANARY" "$WS/escape-symlink"

# --- 3) launcher self-test: policy + probes -------------------------------
# env -i delivers ONLY allowlisted keys to the launcher (the same contract the Ruby
# CommandRunner enforces via unsetenv_others). Probes must ALL be denied by Landlock.
if ! env -i LANG=C LC_ALL=C PATH=/usr/bin:/bin HOME="$WS" TMPDIR="$WS/tmp" XDG_CACHE_HOME="$WS/cache" \
     "$SU_EXEC" marine_sop "$LAUNCHER" --selftest "$WS" \
     "$STORAGE_CANARY" "$CONFIG_CANARY" "$TMP_CANARY" "$WS/escape-symlink" \
     /usr/bin/env /app /proc/self/status 2>/dev/null \
     | grep -qx 'WIJAYA_SOP_SELFTEST:PASS'; then
  fail selftest
fi

# --- 3b) non-allowlisted env key must fail closed -------------------------
if env -i WIJAYA_ENV_CANARY=1 \
     "$SU_EXEC" marine_sop "$LAUNCHER" --selftest "$WS" "$TMP_CANARY" >/dev/null 2>&1; then
  fail env-canary
fi

# --- 3c) exec mode must refuse every non-parser exec target ------------------
# The launcher's own argv[3] allowlist: EXACTLY the four parsers, never the
# musl loader or anything else. /bin/sh stands in for every other executable.
if env -i LANG=C LC_ALL=C PATH=/usr/bin:/bin HOME="$WS" TMPDIR="$WS/tmp" XDG_CACHE_HOME="$WS/cache" \
     "$SU_EXEC" marine_sop "$LAUNCHER" "$WS" -- /bin/sh -c "exit 9" >/dev/null 2>&1; then
  fail exec-target
fi

# --- 4) real parsers through the REAL sandbox (synthetic PDF) ------------
# Minimal single-page PDF with a Helvetica text run; Poppler tolerates the absent
# xref (it reconstructs it), so no external PDF tooling is needed in the gate.
PDF="$WS/doc.pdf"
su-exec marine_sop tee "$PDF" >/dev/null <<'PDFEOF'
%PDF-1.4
1 0 obj
<</Type/Catalog/Pages 2 0 R>>
endobj
2 0 obj
<</Type/Pages/Kids[3 0 R]/Count 1>>
endobj
3 0 obj
<</Type/Page/Parent 2 0 R/MediaBox[0 0 300 150]/Resources<</Font<</F1 5 0 R>>>>/Contents 4 0 R>>
endobj
4 0 obj
<</Length 49>>
stream
BT /F1 18 Tf 20 70 Td (ALPHA BRAVO CHARLIE) Tj ET
endstream
endobj
5 0 obj
<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>
endobj
trailer
<</Root 1 0 R/Size 6>>
PDFEOF
su-exec marine_sop chmod 0644 "$PDF"

# Helper: run a parser under su-exec + the sandbox with the exact allowlisted env.
# The launcher signature is <workspace> -- <binary> [args...]; every probe parser run
# shares the gate's marine_sop-owned workspace.
run_sandboxed() {
  env -i LANG=C LC_ALL=C PATH=/usr/bin:/bin HOME="$WS" TMPDIR="$WS/tmp" XDG_CACHE_HOME="$WS/cache" \
    "$SU_EXEC" marine_sop "$LAUNCHER" "$WS" "$@" 2>/dev/null
}

out="$(run_sandboxed -- /usr/bin/pdfinfo "$PDF")" || fail pdfinfo
printf '%s\n' "$out" | grep -q '^Pages:.*1' || fail pdfinfo

out="$(run_sandboxed -- /usr/bin/pdftotext -layout "$PDF" -)" || fail pdftotext
printf '%s\n' "$out" | grep -q 'ALPHA' || fail pdftotext

run_sandboxed -- /usr/bin/pdftoppm -png -r 100 -singlefile "$PDF" "$WS/page" || fail pdftoppm
# Checked AS marine_sop: the gate root process has no CAP_DAC_OVERRIDE
# (cap_drop ALL), so it cannot traverse the marine_sop-owned 0700 workspace.
su-exec marine_sop test -f "$WS/page.png" || fail pdftoppm

run_sandboxed -- /usr/bin/tesseract "$WS/page.png" stdout -l ind+eng >/dev/null || fail tesseract

# --- 5) parent CAP_KILL over a real privilege-dropped child ----------------
# The gate process itself runs as root inside the worker container (docker exec /
# docker run defaults), so it holds exactly the container's capability set
# (cap_drop ALL + cap_add CHOWN/SETUID/SETGID/KILL). This probe proves the
# parent-side kill capability the CommandRunner deadline/reaper code depends
# on: a REAL su-exec identity drop to marine_sop, followed by a process-group
# SIGKILL of that fully privilege-dropped child. Requires the child to die by
# SIGKILL (signaled success) and guarantees cleanup (kill + reap) on every
# path. All output is suppressed; no path, user or capability value is printed.
# ruby exists in this image (it is the Rails application image).
if ! ruby - <<'RUBYKILLPROBE' >/dev/null 2>&1
  # Secret-safe real identity-drop kill probe: spawn su-exec -> marine_sop ->
  # /bin/sh in its own process group, wait for a PRIVATE fd-3 readiness
  # handshake (one fixed byte written only AFTER su-exec has completed the
  # uid/gid drop, so the parent never kills a racing pre-drop child), then
  # SIGKILL the whole dropped group and require signaled success with
  # guaranteed cleanup. All pipe fds/processes are closed/killed/reaped on
  # every path.
  su_exec = %w[/sbin/su-exec /usr/sbin/su-exec /usr/bin/su-exec /bin/su-exec].find { |p| File.executable?(p) }
  exit 1 unless su_exec
  ready_byte = 'q'
  pid = nil
  reaped = false
  read_io = nil
  write_io = nil
  begin
    read_io, write_io = IO.pipe
    # fd 3 is the inherited readiness pipe: the /bin/sh -c body runs only
    # after the su-exec identity drop, so the single fixed byte proves the
    # drop landed before any kill is allowed.
    pid = Process.spawn(su_exec, 'marine_sop', '/bin/sh', '-c',
                        "printf '#{ready_byte}' >&3; exec 3>&-; exec /bin/sleep 30",
                        pgroup: true, out: File::NULL, err: File::NULL,
                        3 => write_io)
    write_io.close
    ready = IO.select([read_io], nil, nil, 5)
    exit 1 unless ready
    exit 1 unless read_io.read(1) == ready_byte
    Process.kill('-KILL', pid)
    _pid, status = Process.wait2(pid)
    reaped = true
    exit(status.signaled? && status.termsig == Signal.list['KILL'] ? 0 : 1)
  rescue StandardError
    exit 1
  ensure
    if pid && !reaped
      begin
        Process.kill('-KILL', pid)
      rescue StandardError
        nil
      end
      begin
        Process.wait(pid)
      rescue StandardError
        nil
      end
    end
    [read_io, write_io].each do |io|
      next if io.nil? || io.closed?
      begin
        io.close
      rescue StandardError
        nil
      end
    end
  end
RUBYKILLPROBE
then
  fail kill-probe
fi

echo "$SENTINEL:PASS"
