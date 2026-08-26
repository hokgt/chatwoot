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
      stateToken: null,
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
      stateToken: null,
    });
  });

  it('echoes the signed state token from a response on the next request', async () => {
    playgroundSpy.mockResolvedValue({
      data: { action: 'reply', response: 'first', state_token: 'signed-1' },
    });
    const wrapper = mountPlayground();
    await send(wrapper, 'first');
    await flushPromises();

    playgroundSpy.mockResolvedValue({
      data: { action: 'reply', response: 'second', state_token: 'signed-2' },
    });
    await send(wrapper, 'second');
    await flushPromises();

    expect(playgroundSpy).toHaveBeenLastCalledWith(
      expect.objectContaining({
        messageContent: 'second',
        stateToken: 'signed-1',
      })
    );
  });

  it('clears the state token on a manual reset so the next request starts a fresh flow', async () => {
    playgroundSpy.mockResolvedValue({
      data: { action: 'reply', response: 'first', state_token: 'signed-1' },
    });
    const wrapper = mountPlayground();
    await send(wrapper, 'first');
    await flushPromises();

    wrapper.vm.resetConversation();
    playgroundSpy.mockResolvedValue({
      data: { action: 'reply', response: 'fresh' },
    });
    await send(wrapper, 'again');
    await flushPromises();

    expect(playgroundSpy).toHaveBeenLastCalledWith(
      expect.objectContaining({ messageContent: 'again', stateToken: null })
    );
  });

  it('clears the state token on assistant switch', async () => {
    playgroundSpy.mockResolvedValue({
      data: { action: 'reply', response: 'first', state_token: 'signed-1' },
    });
    const wrapper = mountPlayground(1);
    await send(wrapper, 'first');
    await flushPromises();

    await wrapper.setProps({ assistantId: 2 });
    playgroundSpy.mockResolvedValue({
      data: { action: 'reply', response: 'fresh' },
    });
    await send(wrapper, 'again');
    await flushPromises();

    expect(playgroundSpy).toHaveBeenLastCalledWith(
      expect.objectContaining({ assistantId: 2, stateToken: null })
    );
  });

  it('does not let a stale response repopulate the state token after a reset', async () => {
    const first = deferred();
    playgroundSpy.mockReturnValueOnce(first.promise);
    const wrapper = mountPlayground();

    await send(wrapper, 'hello');
    wrapper.vm.resetConversation();
    first.resolve({
      data: { action: 'reply', response: 'stale', state_token: 'stale-token' },
    });
    await flushPromises();

    playgroundSpy.mockResolvedValue({
      data: { action: 'reply', response: 'fresh' },
    });
    await send(wrapper, 'world');
    await flushPromises();
    // The stale token was discarded; the fresh request started from null.
    expect(playgroundSpy).toHaveBeenLastCalledWith(
      expect.objectContaining({ messageContent: 'world', stateToken: null })
    );
  });

  it('attaches a catalog preview card payload to the assistant message', async () => {
    playgroundSpy.mockResolvedValue({
      data: {
        action: 'reply',
        response: 'The Baby Doll catalog is available.',
        catalog_preview: {
          family_name: 'Baby Doll',
          filename: 'catalog.pdf',
          content_type: 'application/pdf',
          byte_size: 2048,
        },
      },
    });
    const wrapper = mountPlayground();
    await send(wrapper, 'ada katalog baby doll ?');
    await flushPromises();

    expect(wrapper.vm.messages[1]).toEqual(
      expect.objectContaining({
        sender: 'assistant',
        catalogPreview: expect.objectContaining({
          family_name: 'Baby Doll',
          filename: 'catalog.pdf',
        }),
      })
    );
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

  it('discards a late success that resolves after a manual reset', async () => {
    const first = deferred();
    playgroundSpy.mockReturnValueOnce(first.promise);
    const wrapper = mountPlayground();

    await send(wrapper, 'hello');
    // Manual reset (same assistant) while the request is still in flight.
    wrapper.vm.resetConversation();
    // The stale response now arrives — it must not repopulate the cleared transcript.
    first.resolve({ data: { action: 'reply', response: 'stale answer' } });
    await flushPromises();

    expect(wrapper.vm.messages).toEqual([]);
    expect(wrapper.vm.isLoading).toBe(false);
  });

  it('discards a late error that rejects after a manual reset', async () => {
    const first = deferred();
    playgroundSpy.mockReturnValueOnce(first.promise);
    const wrapper = mountPlayground();

    await send(wrapper, 'hello');
    wrapper.vm.resetConversation();
    first.reject(new Error('boom'));
    await flushPromises();

    // No error turn appended onto the fresh transcript.
    expect(wrapper.vm.messages).toEqual([]);
    expect(wrapper.vm.isLoading).toBe(false);
  });

  it('lets only the new request own the transcript and loading after reset, regardless of order', async () => {
    const first = deferred();
    const second = deferred();
    playgroundSpy.mockReturnValueOnce(first.promise);
    const wrapper = mountPlayground();

    await send(wrapper, 'hello');
    // Manual reset while the first request is in flight, then start a fresh request.
    wrapper.vm.resetConversation();
    playgroundSpy.mockReturnValueOnce(second.promise);
    await send(wrapper, 'world');

    // The old request resolves first: it must not touch the fresh transcript or loading state.
    first.resolve({ data: { action: 'reply', response: 'stale answer' } });
    await flushPromises();
    expect(wrapper.vm.messages).toEqual([
      expect.objectContaining({ sender: 'user', content: 'world' }),
    ]);
    expect(wrapper.vm.isLoading).toBe(true);

    // Only the new request populates the transcript and clears its own loading state.
    second.resolve({ data: { action: 'reply', response: 'fresh answer' } });
    await flushPromises();
    expect(wrapper.vm.messages).toEqual([
      expect.objectContaining({ sender: 'user', content: 'world' }),
      expect.objectContaining({ sender: 'assistant', content: 'fresh answer' }),
    ]);
    expect(wrapper.vm.isLoading).toBe(false);
  });

  it('does not let the old request clear loading when the new one resolves first', async () => {
    const first = deferred();
    const second = deferred();
    playgroundSpy.mockReturnValueOnce(first.promise);
    const wrapper = mountPlayground();

    await send(wrapper, 'hello');
    wrapper.vm.resetConversation();
    playgroundSpy.mockReturnValueOnce(second.promise);
    await send(wrapper, 'world');

    // New request resolves first and owns the loading state.
    second.resolve({ data: { action: 'reply', response: 'fresh answer' } });
    await flushPromises();
    expect(wrapper.vm.isLoading).toBe(false);
    const transcriptAfterNew = [...wrapper.vm.messages];

    // The stale first request now resolves: it must not append or mutate anything.
    first.resolve({ data: { action: 'reply', response: 'stale answer' } });
    await flushPromises();
    expect(wrapper.vm.messages).toEqual(transcriptAfterNew);
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
