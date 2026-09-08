// WIJAYA_CUSTOM persistent_agent_presence
//
// Background-tab-resilient presence heartbeat.
//
// Chatwoot treats an agent as online only while the browser keeps sending the
// `update_presence` ping inside the backend presence window (PRESENCE_DURATION,
// 20s — lib/online_status_tracker.rb). Upstream drives that ping from a
// main-thread recursive `setTimeout`. Browsers throttle main-thread timers in
// backgrounded tabs (Chrome "intensive throttling" wakes them at most once per
// minute after a tab has been hidden for 5 minutes), so a throttled 20s ping
// lands well past the 20s window. The result: an authenticated agent whose tab
// is merely open-but-unfocused (Excel, another tab, etc.) silently drops out of
// presence and stops receiving auto-assignments.
//
// A dedicated Web Worker owns the timer instead. A worker timer avoids the
// ordinary main-thread hidden-tab throttling that delays the upstream ping, so
// the heartbeat keeps its cadence while the page stays loaded. A worker is not
// absolutely exempt from every browser/OS suspension, though: a fully frozen,
// discarded, or killed page/process cannot run its timer at all — those cases
// stop the pings and the native Redis presence window then expires the agent, as
// intended. That TTL remains the dead-client safety net — this never fakes
// presence for a client that is truly gone.
//
// The supplied interval equals the backend presence window, whose check is a
// strict `connected_time > now - window` on integer-second timestamps. Pinging
// once per window leaves zero slack for timer jitter, tick delivery, and
// ActionCable/network latency, so a slightly late ping can briefly expire
// presence. The worker therefore heartbeats at a bounded fraction (half) of the
// window (WORKER_HEARTBEAT_DIVISOR) to keep comfortable margin.

const WORKER_SOURCE = `
  let timerId = null;
  self.onmessage = function (event) {
    const data = event.data || {};
    if (data.command === 'start') {
      if (timerId !== null) { clearInterval(timerId); }
      timerId = setInterval(function () { self.postMessage('tick'); }, data.interval);
    } else if (data.command === 'stop') {
      if (timerId !== null) { clearInterval(timerId); timerId = null; }
    }
  };
`;

// Heartbeat at half the supplied window so presence has margin below the strict
// backend TTL (see header). `Math.max(1, …)` floors the result at 1ms so an
// arbitrarily small injected interval can never yield a zero/sub-millisecond
// interval that would spin or stall the worker timer.
const WORKER_HEARTBEAT_DIVISOR = 2;

function workerHeartbeatInterval(intervalMs) {
  return Math.max(1, Math.floor(intervalMs / WORKER_HEARTBEAT_DIVISOR));
}

// Main-thread fallback, used only when Web Workers are unavailable or blocked.
// It reproduces the upstream recursive-setTimeout behaviour at the upstream
// cadence (the full supplied interval) so presence never regresses below
// upstream in unsupported environments. It is deliberately not tightened: a
// main-thread timer is throttled in a hidden tab regardless, so a shorter cadence
// would not buy reliable margin there, and preserving exact upstream behaviour is
// preferable for the fallback path.
function createTimeoutHeartbeat(onTick, intervalMs) {
  let stopped = false;
  let timeoutId = null;
  const schedule = () => {
    timeoutId = setTimeout(() => {
      if (stopped) return;
      onTick();
      schedule();
    }, intervalMs);
  };
  schedule();
  return () => {
    stopped = true;
    if (timeoutId !== null) clearTimeout(timeoutId);
  };
}

// Starts a heartbeat that invokes `onTick` every `intervalMs` and returns an
// idempotent stop() that tears the heartbeat (and its worker) down.
export function createPersistentPresenceHeartbeat(onTick, intervalMs) {
  if (typeof Worker === 'undefined') {
    return createTimeoutHeartbeat(onTick, intervalMs);
  }

  let objectUrl = null;
  let worker = null;
  try {
    const blob = new Blob([WORKER_SOURCE], { type: 'application/javascript' });
    objectUrl = URL.createObjectURL(blob);
    worker = new Worker(objectUrl);
  } catch (error) {
    if (objectUrl) URL.revokeObjectURL(objectUrl);
    return createTimeoutHeartbeat(onTick, intervalMs);
  }

  worker.onmessage = () => onTick();
  worker.postMessage({
    command: 'start',
    interval: workerHeartbeatInterval(intervalMs),
  });

  let stopped = false;
  return () => {
    if (stopped) return;
    stopped = true;
    try {
      worker.postMessage({ command: 'stop' });
    } catch (error) {
      // Worker may already be gone; terminate below is the real cleanup.
    }
    worker.terminate();
    if (objectUrl) URL.revokeObjectURL(objectUrl);
  };
}
