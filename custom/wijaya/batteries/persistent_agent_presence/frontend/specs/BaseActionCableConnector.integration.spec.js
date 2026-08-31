import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';

// Mock the ActionCable consumer so the connector can be constructed in jsdom.
const hoisted = vi.hoisted(() => ({ consumer: null }));
vi.mock('@rails/actioncable', () => ({
  createConsumer: vi.fn(() => hoisted.consumer),
}));

import BaseActionCableConnector from 'shared/helpers/BaseActionCableConnector';

// Same fake worker as the unit spec: its timer lives off the main thread, so it
// is not throttled when the tab is backgrounded. Ticks are driven explicitly.
class FakeWorker {
  constructor() {
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
    if (this.onmessage && !this.terminated) this.onmessage({ data: 'tick' });
  }
}
FakeWorker.instances = [];

const buildApp = () => ({
  $store: {
    getters: {
      getCurrentAccountId: 1,
      getCurrentUserID: 7,
    },
  },
});

describe('BaseActionCableConnector persistent presence integration', () => {
  let performSpy;
  let disconnectSpy;
  let originalWorker;
  let originalCreate;
  let originalRevoke;

  beforeEach(() => {
    FakeWorker.instances = [];
    performSpy = vi.fn();
    disconnectSpy = vi.fn();

    hoisted.consumer = {
      connection: { isOpen: () => true },
      disconnect: disconnectSpy,
      subscriptions: {
        create: (_params, mixin) => ({ perform: performSpy, ...mixin }),
      },
    };

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
    hoisted.consumer = null;
  });

  it('drives update_presence from a worker-backed heartbeat', () => {
    // RED against upstream: upstream uses a bare main-thread setTimeout and never
    // constructs a Worker, so this assertion fails until the battery hook is wired.
    const connector = new BaseActionCableConnector(buildApp(), 'token');

    expect(connector).toBeTruthy();
    expect(FakeWorker.instances).toHaveLength(1);
    expect(FakeWorker.instances[0].posted).toContainEqual({
      command: 'start',
      interval: 20000,
    });
  });

  it('keeps sending update_presence while the tab is hidden', () => {
    const connector = new BaseActionCableConnector(buildApp(), 'token');
    expect(connector).toBeTruthy();
    const worker = FakeWorker.instances[0];

    Object.defineProperty(document, 'hidden', {
      configurable: true,
      get: () => true,
    });
    worker.emitTick();
    worker.emitTick();

    expect(performSpy).toHaveBeenCalledTimes(2);
    expect(performSpy).toHaveBeenCalledWith('update_presence');
  });

  it('stops the heartbeat and terminates the worker on disconnect (no immortal presence)', () => {
    const connector = new BaseActionCableConnector(buildApp(), 'token');
    const worker = FakeWorker.instances[0];

    connector.disconnect();

    expect(worker.terminated).toBe(true);
    expect(disconnectSpy).toHaveBeenCalled();

    worker.emitTick();
    expect(performSpy).not.toHaveBeenCalled();
  });
});
