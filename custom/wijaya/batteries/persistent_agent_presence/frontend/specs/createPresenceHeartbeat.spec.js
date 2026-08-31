import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { createPersistentPresenceHeartbeat } from '../createPresenceHeartbeat';

// A fake dedicated Worker whose timer lives outside the main thread, so it is
// NOT subject to the browser background-tab throttling that delays the upstream
// main-thread setTimeout ping. Tests drive ticks explicitly via emitTick().
class FakeWorker {
  constructor(url) {
    this.url = url;
    this.onmessage = null;
    this.posted = [];
    this.terminated = false;
    FakeWorker.instances.push(this);
  }

  postMessage(msg) {
    this.posted.push(msg);
  }

  terminate() {
    this.terminated = true;
  }

  emitTick() {
    if (this.onmessage) this.onmessage({ data: 'tick' });
  }
}
FakeWorker.instances = [];

describe('createPersistentPresenceHeartbeat', () => {
  describe('with Web Worker support', () => {
    let originalWorker;
    let originalCreate;
    let originalRevoke;

    beforeEach(() => {
      FakeWorker.instances = [];
      originalWorker = global.Worker;
      originalCreate = global.URL.createObjectURL;
      originalRevoke = global.URL.revokeObjectURL;
      global.Worker = FakeWorker;
      global.URL.createObjectURL = vi.fn(() => 'blob:presence');
      global.URL.revokeObjectURL = vi.fn();
    });

    afterEach(() => {
      global.Worker = originalWorker;
      global.URL.createObjectURL = originalCreate;
      global.URL.revokeObjectURL = originalRevoke;
    });

    it('drives the heartbeat from a worker timer, not a main-thread timer', () => {
      const onTick = vi.fn();
      createPersistentPresenceHeartbeat(onTick, 20000);

      expect(FakeWorker.instances).toHaveLength(1);
      expect(FakeWorker.instances[0].posted).toEqual([
        { command: 'start', interval: 20000 },
      ]);
    });

    it('keeps firing while the tab is hidden/unfocused (worker is unthrottled)', () => {
      const onTick = vi.fn();
      createPersistentPresenceHeartbeat(onTick, 20000);
      const worker = FakeWorker.instances[0];

      // Simulate a backgrounded tab: the main thread would throttle a setTimeout,
      // but the worker still delivers ticks.
      Object.defineProperty(document, 'hidden', {
        configurable: true,
        get: () => true,
      });
      worker.emitTick();
      worker.emitTick();
      worker.emitTick();

      expect(onTick).toHaveBeenCalledTimes(3);
    });

    it('stop() halts pings and terminates the worker (no immortal presence)', () => {
      const onTick = vi.fn();
      const stop = createPersistentPresenceHeartbeat(onTick, 20000);
      const worker = FakeWorker.instances[0];

      stop();

      expect(worker.posted).toContainEqual({ command: 'stop' });
      expect(worker.terminated).toBe(true);
      expect(global.URL.revokeObjectURL).toHaveBeenCalledWith('blob:presence');
    });

    it('stop() is idempotent', () => {
      const onTick = vi.fn();
      const stop = createPersistentPresenceHeartbeat(onTick, 20000);
      const worker = FakeWorker.instances[0];

      stop();
      stop();

      const stopMessages = worker.posted.filter(m => m.command === 'stop');
      expect(stopMessages).toHaveLength(1);
    });
  });

  describe('fallback without Web Worker support', () => {
    let originalWorker;

    beforeEach(() => {
      vi.useFakeTimers();
      originalWorker = global.Worker;
      global.Worker = undefined;
    });

    afterEach(() => {
      vi.useRealTimers();
      global.Worker = originalWorker;
    });

    it('falls back to a recursive timer and keeps pinging on cadence', () => {
      const onTick = vi.fn();
      createPersistentPresenceHeartbeat(onTick, 20000);

      expect(onTick).not.toHaveBeenCalled();
      vi.advanceTimersByTime(20000);
      expect(onTick).toHaveBeenCalledTimes(1);
      vi.advanceTimersByTime(20000);
      expect(onTick).toHaveBeenCalledTimes(2);
    });

    it('stop() halts the fallback timer', () => {
      const onTick = vi.fn();
      const stop = createPersistentPresenceHeartbeat(onTick, 20000);

      vi.advanceTimersByTime(20000);
      expect(onTick).toHaveBeenCalledTimes(1);
      stop();
      vi.advanceTimersByTime(60000);
      expect(onTick).toHaveBeenCalledTimes(1);
    });
  });
});
