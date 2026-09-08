import { computed } from 'vue';
import { withMarineCaptain } from '@wijaya/marine_ai/frontend/useMarineCaptain';
import {
  useFunctionGetter,
  useMapGetter,
} from 'dashboard/composables/store.js';
import { useI18n } from 'vue-i18n';
import MarineTasksAPI from '@wijaya/marine_ai/frontend/api/tasks';

vi.mock('dashboard/composables/store.js');
vi.mock('vue-i18n');
vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));
vi.mock('@wijaya/marine_ai/frontend/api/tasks');

// Builds a stand-in for the native useCaptain() return so the adapter can be
// tested in isolation. Every task method is a spy resolving to a native marker.
const buildNativeCaptain = () => ({
  captainEnabled: computed(() => true),
  captainTasksEnabled: computed(() => false),
  draftMessage: { value: 'draft' },
  currentChat: { value: { id: '123' } },
  rewriteContent: vi.fn().mockResolvedValue({ message: 'native-rewrite' }),
  summarizeConversation: vi
    .fn()
    .mockResolvedValue({ message: 'native-summary' }),
  getReplySuggestion: vi.fn().mockResolvedValue({ message: 'native-reply' }),
  followUp: vi.fn().mockResolvedValue({ message: 'native-followup' }),
  processEvent: vi.fn().mockResolvedValue({ message: 'native-process' }),
});

const setInbox = ({ marine } = {}) => {
  useMapGetter.mockImplementation(getter => {
    const values = {
      getSelectedChat: { id: '123', inbox_id: 55 },
      'draftMessages/getReplyEditorMode': 'reply',
      'inboxes/getInbox': inboxId =>
        marine && inboxId === 55 ? { id: 55, marine_assistant_id: 7 } : {},
    };
    return { value: values[getter] };
  });
};

describe('withMarineCaptain', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    useFunctionGetter.mockReturnValue({ value: 'draft' });
    useI18n.mockReturnValue({ t: vi.fn() });
    setInbox({ marine: false });
  });

  it('delegates every task method to the native captain for non-Marine inboxes', async () => {
    const native = buildNativeCaptain();
    const captain = withMarineCaptain(native);

    expect((await captain.rewriteContent('c', 'improve', {})).message).toBe(
      'native-rewrite'
    );
    expect((await captain.summarizeConversation({})).message).toBe(
      'native-summary'
    );
    expect((await captain.getReplySuggestion({})).message).toBe('native-reply');
    expect((await captain.followUp({})).message).toBe('native-followup');
    await captain.processEvent('translate', 'c', { targetLanguage: 'id' });

    expect(native.processEvent).toHaveBeenCalledWith('translate', 'c', {
      targetLanguage: 'id',
    });
    expect(MarineTasksAPI.rewrite).not.toHaveBeenCalled();
    expect(MarineTasksAPI.translate).not.toHaveBeenCalled();
  });

  it('routes task methods through Marine tasks for Marine-linked inboxes', async () => {
    setInbox({ marine: true });
    MarineTasksAPI.rewrite.mockResolvedValue({
      data: { message: 'marine-rewrite', follow_up_context: { id: 'm1' } },
    });
    const native = buildNativeCaptain();
    const captain = withMarineCaptain(native);

    const result = await captain.rewriteContent('c', 'improve', {});

    expect(MarineTasksAPI.rewrite).toHaveBeenCalled();
    expect(native.rewriteContent).not.toHaveBeenCalled();
    expect(result).toEqual({
      message: 'marine-rewrite',
      followUpContext: { id: 'm1' },
    });
  });

  it('enables composer tasks for Marine inboxes even when native is disabled', () => {
    setInbox({ marine: true });
    const captain = withMarineCaptain(buildNativeCaptain());
    expect(captain.captainTasksEnabled.value).toBe(true);
  });

  it('falls back to an empty message with an error type when Marine tasks fail', async () => {
    setInbox({ marine: true });
    MarineTasksAPI.rewrite.mockRejectedValue({ response: { status: 500 } });
    const captain = withMarineCaptain(buildNativeCaptain());

    const result = await captain.rewriteContent('c', 'improve', {});

    expect(result.message).toBe('');
    expect(result.errorType).toBeDefined();
  });

  it('passes content through unchanged when translating a non-Marine conversation', async () => {
    const captain = withMarineCaptain(buildNativeCaptain());
    const result = await captain.translateContent('Hello', 'id', {});
    expect(result).toEqual({ message: 'Hello' });
    expect(MarineTasksAPI.translate).not.toHaveBeenCalled();
  });
});
