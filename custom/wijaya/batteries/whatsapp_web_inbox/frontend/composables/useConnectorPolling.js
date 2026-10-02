import { ref, onBeforeUnmount } from 'vue';

// Safe, self-contained poller for connector status/QR:
//   - setTimeout recursion (never setInterval) so ticks can never stack up,
//   - an in-flight guard so a slow response never triggers a concurrent call,
//   - slows to `hiddenInterval` while the tab is hidden and speeds back up on focus,
//   - stops on unmount and removes its visibility listener (no runaway intervals).
// `callback` is awaited each tick; it should swallow/surface its own errors — a throw is
// caught here so polling continues.
export function useConnectorPolling(
  callback,
  { interval = 3000, hiddenInterval = 15000 } = {}
) {
  let timer = null;
  let inFlight = false;
  let stopped = true;
  const isPolling = ref(false);

  const documentHidden = () =>
    typeof document !== 'undefined' && document.hidden;

  const currentInterval = () => (documentHidden() ? hiddenInterval : interval);

  const schedule = () => {
    if (timer) clearTimeout(timer);
    timer = null;
    if (stopped) return;
    // tick is a hoisted function declaration below; schedule/tick are mutually recursive.
    // eslint-disable-next-line no-use-before-define
    timer = setTimeout(tick, currentInterval());
  };

  async function tick() {
    if (stopped) return;
    if (inFlight) {
      schedule();
      return;
    }
    inFlight = true;
    try {
      await callback();
    } catch (error) {
      // Polling is best-effort; the callback owns user-facing error state.
    } finally {
      inFlight = false;
      schedule();
    }
  }

  const onVisibilityChange = () => {
    if (!stopped) schedule();
  };

  const start = () => {
    if (!stopped) return;
    stopped = false;
    isPolling.value = true;
    tick();
  };

  const stop = () => {
    stopped = true;
    isPolling.value = false;
    if (timer) clearTimeout(timer);
    timer = null;
  };

  if (typeof document !== 'undefined') {
    document.addEventListener('visibilitychange', onVisibilityChange);
  }

  onBeforeUnmount(() => {
    stop();
    if (typeof document !== 'undefined') {
      document.removeEventListener('visibilitychange', onVisibilityChange);
    }
  });

  return { start, stop, isPolling };
}

export default useConnectorPolling;
