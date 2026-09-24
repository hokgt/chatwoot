// WIJAYA_CUSTOM_START erp_lead_sidebar
import { ref, computed } from 'vue';

// Explicit per-dependency lazy loader for the manual Lead Activity form. Each ERP
// dependency (Activity Master, Person In Charge) owns one instance, so their
// loading / loaded / error / retry / refresh states stay fully independent.
//
// Contract:
//   * `state` is one of 'idle' | 'loading' | 'loaded' | 'error' and is NEVER
//     inferred from the option count — a valid empty list is a real 'loaded'
//     state, distinct from an unfetched 'idle' or a failed 'error'.
//   * load() fetches once. Concurrent load() calls reuse the same in-flight
//     promise (dedupe). A load() while already 'loaded' reuses the cache and does
//     NOT refetch. A load() from 'error' refetches (that is Retry).
//   * refresh() always starts a fresh fetch, superseding any in-flight request,
//     even when already loaded (that is Refresh).
//   * Responses from a superseded request — a newer load()/refresh(), or a reset()
//     after a conversation/account change — are ignored, so stale data can never
//     win.
//
// `fetcher` is an async function resolving to the option array.
export function useLazyErpResource(fetcher) {
  const state = ref('idle');
  const data = ref([]);
  const error = ref('');

  // Monotonic request token; only the newest request may commit its result.
  let requestSeq = 0;
  let inFlight = null;

  const isLoading = computed(() => state.value === 'loading');
  const isLoaded = computed(() => state.value === 'loaded');
  const isError = computed(() => state.value === 'error');

  const messageFor = e =>
    e?.response?.data?.error || 'This list is currently unavailable.';

  const run = () => {
    requestSeq += 1;
    const seq = requestSeq;
    state.value = 'loading';
    error.value = '';
    const promise = Promise.resolve()
      .then(fetcher)
      .then(result => {
        if (seq !== requestSeq) return; // superseded — ignore late success
        data.value = Array.isArray(result) ? result : [];
        state.value = 'loaded';
        inFlight = null;
      })
      .catch(e => {
        if (seq !== requestSeq) return; // superseded — ignore late failure
        error.value = messageFor(e);
        state.value = 'error';
        inFlight = null;
      });
    inFlight = promise;
    return promise;
  };

  // Lazy load: reuse the cache when already loaded, dedupe an in-flight request,
  // and (re)fetch from idle/error.
  const load = () => {
    if (state.value === 'loaded') return Promise.resolve();
    if (inFlight) return inFlight;
    return run();
  };

  // Explicit refresh: always refetch, superseding any in-flight request. Selected
  // values are owned by the caller and are never touched here.
  const refresh = () => run();

  // Reset on conversation/account change: drop cache + state and invalidate any
  // in-flight response so it can never commit late.
  const reset = () => {
    requestSeq += 1;
    inFlight = null;
    state.value = 'idle';
    data.value = [];
    error.value = '';
  };

  return {
    state,
    data,
    error,
    isLoading,
    isLoaded,
    isError,
    load,
    refresh,
    reset,
  };
}
// WIJAYA_CUSTOM_END erp_lead_sidebar
