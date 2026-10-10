import { mount } from '@vue/test-utils';
import { defineComponent, h } from 'vue';
import { useConnectorPolling } from '@wijaya/whatsapp_web_inbox/frontend/composables/useConnectorPolling';

const mountWith = (cb, opts) => {
  let controls;
  const Comp = defineComponent({
    setup() {
      controls = useConnectorPolling(cb, opts);
      return () => h('div');
    },
  });
  const wrapper = mount(Comp);
  return { wrapper, controls: () => controls };
};

const setHidden = value =>
  Object.defineProperty(document, 'hidden', {
    configurable: true,
    get: () => value,
  });

describe('useConnectorPolling', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    setHidden(false);
  });

  afterEach(() => {
    vi.useRealTimers();
    setHidden(false);
  });

  it('calls back immediately and then on each interval', async () => {
    const cb = vi.fn().mockResolvedValue();
    const { controls } = mountWith(cb, { interval: 1000 });

    controls().start();
    expect(cb).toHaveBeenCalledTimes(1);

    await vi.advanceTimersByTimeAsync(1000);
    expect(cb).toHaveBeenCalledTimes(2);

    await vi.advanceTimersByTimeAsync(1000);
    expect(cb).toHaveBeenCalledTimes(3);
  });

  it('stops polling and detaches on unmount (no runaway)', async () => {
    const cb = vi.fn().mockResolvedValue();
    const { wrapper, controls } = mountWith(cb, { interval: 1000 });

    controls().start();
    await vi.advanceTimersByTimeAsync(1000);
    const calls = cb.mock.calls.length;

    wrapper.unmount();
    await vi.advanceTimersByTimeAsync(5000);
    expect(cb).toHaveBeenCalledTimes(calls);
  });

  it('never runs a concurrent call while one is in flight', async () => {
    const cb = vi.fn(() => new Promise(() => {})); // never resolves
    const { controls } = mountWith(cb, { interval: 1000 });

    controls().start();
    expect(cb).toHaveBeenCalledTimes(1);

    // A visibility change arms a timer; it fires while the first call is still pending.
    document.dispatchEvent(new Event('visibilitychange'));
    await vi.advanceTimersByTimeAsync(1000);
    expect(cb).toHaveBeenCalledTimes(1);
  });

  it('slows to the hidden interval while the tab is hidden', async () => {
    const cb = vi.fn().mockResolvedValue();
    const { controls } = mountWith(cb, {
      interval: 1000,
      hiddenInterval: 5000,
    });

    setHidden(true);
    controls().start();
    expect(cb).toHaveBeenCalledTimes(1);

    await vi.advanceTimersByTimeAsync(1000);
    expect(cb).toHaveBeenCalledTimes(1); // not yet — hidden cadence is 5000

    await vi.advanceTimersByTimeAsync(4000);
    expect(cb).toHaveBeenCalledTimes(2);
  });
});
