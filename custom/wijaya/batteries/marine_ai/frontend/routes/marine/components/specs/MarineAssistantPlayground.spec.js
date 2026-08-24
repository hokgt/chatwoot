import { mount, flushPromises } from '@vue/test-utils';
import MarineAssistantPlayground from '@wijaya/marine_ai/frontend/routes/marine/components/MarineAssistantPlayground.vue';

// i18n stub: keys pass through so template renders deterministically.
vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

const { playgroundSpy } = vi.hoisted(() => ({ playgroundSpy: vi.fn() }));
vi.mock('@wijaya/marine_ai/frontend/api/assistant', () => ({
  default: { playground: playgroundSpy },
}));

// Deferred promise helper so we can drive races (late response, duplicate submit) explicitly.
const deferred = () => {
  let resolve;
  let reject;
  const promise = new Promise((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
};

const mountPlayground = (assistantId = 1) =>
  mount(MarineAssistantPlayground, {
    props: { assistantId },
    global: {
      stubs: {
        Button: { template: '<button />' },
        MarineMessageList: {
          props: ['messages', 'isLoading'],
          template: '<div />',
        },
      },
    },
  });

const send = async (wrapper, text) => {
  await wrapper.find('input').setValue(text);
  await wrapper.find('input').trigger('keydown.enter');
};

describe('MarineAssistantPlayground', () => {
  beforeEach(() => vi.clearAllMocks());

  it('sends the first turn with an empty history and records both sides', async () => {
    playgroundSpy.mockResolvedValue({
      data: { action: 'reply', response: 'hi there' },
    });
    const wrapper = mountPlayground();

    await send(wrapper, 'hello');
    await flushPromises();

    expect(playgroundSpy).toHaveBeenCalledWith({
      assistantId: 1,
      messageContent: 'hello',
      messageHistory: [],
    });
    expect(wrapper.vm.messages).toEqual([
      expect.objectContaining({ sender: 'user', content: 'hello' }),
      expect.objectContaining({ sender: 'assistant', content: 'hi there' }),
    ]);
  });

  it('sends the bounded prior transcript as history on a follow-up turn', async () => {
    playgroundSpy.mockResolvedValue({
      data: { action: 'reply', response: 'first reply' },
    });
    const wrapper = mountPlayground();
    await send(wrapper, 'first');
    await flushPromises();

    playgroundSpy.mockResolvedValue({
      data: { action: 'reply', response: 'second reply' },
    });
    await send(wrapper, 'second');
    await flushPromises();

    expect(playgroundSpy).toHaveBeenLastCalledWith({
      assistantId: 1,
      messageContent: 'second',
      messageHistory: [
        { role: 'user', content: 'first' },
        { role: 'assistant', content: 'first reply' },
      ],
    });
  });

  it('renders a handoff turn without content and excludes it from later history', async () => {
    playgroundSpy.mockResolvedValue({
      data: { action: 'handoff', action_reason: 'no_confident_cell_match' },
    });
    const wrapper = mountPlayground();
    await send(wrapper, 'obscure');
    await flushPromises();

    expect(wrapper.vm.messages[1]).toEqual(
      expect.objectContaining({ sender: 'assistant', handoff: true })
    );

    playgroundSpy.mockResolvedValue({
      data: { action: 'reply', response: 'ok' },
    });
    await send(wrapper, 'again');
    await flushPromises();

    // Only the earlier user turn is grounded; the handoff (no content) is excluded.
    expect(playgroundSpy).toHaveBeenLastCalledWith(
      expect.objectContaining({
        messageHistory: [{ role: 'user', content: 'obscure' }],
      })
    );
  });

  it('resets the transcript when the selected assistant changes', async () => {
    playgroundSpy.mockResolvedValue({
      data: { action: 'reply', response: 'hi' },
    });
    const wrapper = mountPlayground(1);
    await send(wrapper, 'hello');
    await flushPromises();
    expect(wrapper.vm.messages).toHaveLength(2);

    await wrapper.setProps({ assistantId: 2 });

    expect(wrapper.vm.messages).toEqual([]);
  });

  it('discards a late response that resolves after an assistant switch', async () => {
    const first = deferred();
    playgroundSpy.mockReturnValueOnce(first.promise);
    const wrapper = mountPlayground(1);

    await send(wrapper, 'hello');
    // Switch assistant while the request is still in flight.
    await wrapper.setProps({ assistantId: 2 });
    // The stale response now arrives.
    first.resolve({ data: { action: 'reply', response: 'stale answer' } });
    await flushPromises();

    expect(wrapper.vm.messages).toEqual([]);
    expect(wrapper.vm.isLoading).toBe(false);
  });

  it('ignores a duplicate submit while a request is in flight', async () => {
    const first = deferred();
    playgroundSpy.mockReturnValueOnce(first.promise);
    const wrapper = mountPlayground();

    await send(wrapper, 'hello');
    // Second submit before the first resolves must be a no-op (guarded by isLoading).
    await send(wrapper, 'again');

    expect(playgroundSpy).toHaveBeenCalledTimes(1);

    first.resolve({ data: { action: 'reply', response: 'done' } });
    await flushPromises();
  });

  it('shows an error turn when the request fails', async () => {
    playgroundSpy.mockRejectedValue(new Error('boom'));
    const wrapper = mountPlayground();

    await send(wrapper, 'hello');
    await flushPromises();

    expect(wrapper.vm.messages[1]).toEqual(
      expect.objectContaining({ sender: 'assistant', error: true })
    );
    expect(wrapper.vm.isLoading).toBe(false);
  });
});
