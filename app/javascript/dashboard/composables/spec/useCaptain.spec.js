import { useCaptain } from '../useCaptain';
import {
  useFunctionGetter,
  useMapGetter,
  useStore,
} from 'dashboard/composables/store';
import { useAccount } from 'dashboard/composables/useAccount';
import { useConfig } from 'dashboard/composables/useConfig';
import { useI18n } from 'vue-i18n';
import TasksAPI from 'dashboard/api/captain/tasks';
import MarineTasksAPI from 'dashboard/api/marine/tasks';

vi.mock('dashboard/composables/store');
vi.mock('dashboard/composables/useAccount');
vi.mock('dashboard/composables/useConfig');
vi.mock('vue-i18n');
vi.mock('dashboard/api/captain/tasks');
vi.mock('dashboard/api/marine/tasks');
vi.mock('dashboard/helper/AnalyticsHelper/index', async importOriginal => {
  const actual = await importOriginal();
  return {
    ...actual,
    default: {
      track: vi.fn(),
    },
  };
});
vi.mock('dashboard/helper/AnalyticsHelper/events', () => ({
  CAPTAIN_EVENTS: {
    TEST_EVENT: 'captain_test_event',
  },
}));

describe('useCaptain', () => {
  const mockStore = {
    dispatch: vi.fn(),
  };

  beforeEach(() => {
    vi.clearAllMocks();
    useStore.mockReturnValue(mockStore);
    useFunctionGetter.mockReturnValue({ value: 'Draft message' });
    useMapGetter.mockImplementation(getter => {
      const mockValues = {
        'accounts/getUIFlags': { isFetchingLimits: false },
        getSelectedChat: { id: '123' },
        'draftMessages/getReplyEditorMode': 'reply',
      };
      return { value: mockValues[getter] };
    });
    useI18n.mockReturnValue({ t: vi.fn() });
    useAccount.mockReturnValue({
      isCloudFeatureEnabled: vi.fn().mockReturnValue(true),
      currentAccount: { value: { limits: { captain: {} } } },
    });
    useConfig.mockReturnValue({
      isEnterprise: false,
    });
  });

  it('initializes computed properties correctly', async () => {
    const { captainEnabled, captainTasksEnabled, currentChat, draftMessage } =
      useCaptain();

    expect(captainEnabled.value).toBe(true);
    expect(captainTasksEnabled.value).toBe(true);
    expect(currentChat.value).toEqual({ id: '123' });
    expect(draftMessage.value).toBe('Draft message');
  });

  it('rewrites content', async () => {
    TasksAPI.rewrite.mockResolvedValue({
      data: { message: 'Rewritten content', follow_up_context: { id: 'ctx1' } },
    });

    const { rewriteContent } = useCaptain();
    const result = await rewriteContent('Original content', 'improve', {});

    expect(TasksAPI.rewrite).toHaveBeenCalledWith(
      {
        content: 'Original content',
        operation: 'improve',
        conversationId: '123',
      },
      undefined
    );
    expect(result).toEqual({
      message: 'Rewritten content',
      followUpContext: { id: 'ctx1' },
    });
  });

  it('summarizes conversation', async () => {
    TasksAPI.summarize.mockResolvedValue({
      data: { message: 'Summary', follow_up_context: { id: 'ctx2' } },
    });

    const { summarizeConversation } = useCaptain();
    const result = await summarizeConversation({});

    expect(TasksAPI.summarize).toHaveBeenCalledWith('123', undefined);
    expect(result).toEqual({
      message: 'Summary',
      followUpContext: { id: 'ctx2' },
    });
  });

  it('gets reply suggestion', async () => {
    TasksAPI.replySuggestion.mockResolvedValue({
      data: { message: 'Reply suggestion', follow_up_context: { id: 'ctx3' } },
    });

    const { getReplySuggestion } = useCaptain();
    const result = await getReplySuggestion({});

    expect(TasksAPI.replySuggestion).toHaveBeenCalledWith('123', undefined);
    expect(result).toEqual({
      message: 'Reply suggestion',
      followUpContext: { id: 'ctx3' },
    });
  });

  it('sends follow-up message', async () => {
    TasksAPI.followUp.mockResolvedValue({
      data: {
        message: 'Follow-up response',
        follow_up_context: { id: 'ctx4' },
      },
    });

    const { followUp } = useCaptain();
    const result = await followUp({
      followUpContext: { id: 'ctx3' },
      message: 'Make it shorter',
    });

    expect(TasksAPI.followUp).toHaveBeenCalledWith(
      {
        followUpContext: { id: 'ctx3' },
        message: 'Make it shorter',
        conversationId: '123',
      },
      undefined
    );
    expect(result).toEqual({
      message: 'Follow-up response',
      followUpContext: { id: 'ctx4' },
    });
  });

  it('processes event and routes to correct method', async () => {
    TasksAPI.summarize.mockResolvedValue({
      data: { message: 'Summary' },
    });
    TasksAPI.replySuggestion.mockResolvedValue({
      data: { message: 'Reply' },
    });
    TasksAPI.rewrite.mockResolvedValue({
      data: { message: 'Rewritten' },
    });

    const { processEvent } = useCaptain();

    // Test summarize
    await processEvent('summarize', '', {});
    expect(TasksAPI.summarize).toHaveBeenCalled();

    // Test reply_suggestion
    await processEvent('reply_suggestion', '', {});
    expect(TasksAPI.replySuggestion).toHaveBeenCalled();

    // Test rewrite (improve)
    await processEvent('improve', 'content', {});
    expect(TasksAPI.rewrite).toHaveBeenCalled();
  });

  describe('Marine routing', () => {
    beforeEach(() => {
      useMapGetter.mockImplementation(getter => {
        const mockValues = {
          'accounts/getUIFlags': { isFetchingLimits: false },
          getSelectedChat: { id: '123', inbox_id: 55 },
          'draftMessages/getReplyEditorMode': 'reply',
          'inboxes/getInbox': inboxId =>
            inboxId === 55 ? { id: 55, marine_assistant_id: 7 } : {},
        };
        return { value: mockValues[getter] };
      });
    });

    it('flags the conversation as Marine-linked', () => {
      const { isMarineConversation } = useCaptain();
      expect(isMarineConversation.value).toBe(true);
    });

    it('routes rewrite to Marine tasks for Marine-linked inboxes', async () => {
      MarineTasksAPI.rewrite.mockResolvedValue({
        data: { message: 'Marine rewrite', follow_up_context: { id: 'm1' } },
      });

      const { rewriteContent } = useCaptain();
      const result = await rewriteContent('Original content', 'improve', {});

      expect(MarineTasksAPI.rewrite).toHaveBeenCalledWith(
        {
          content: 'Original content',
          operation: 'improve',
          conversationId: '123',
        },
        undefined
      );
      expect(TasksAPI.rewrite).not.toHaveBeenCalled();
      expect(result).toEqual({
        message: 'Marine rewrite',
        followUpContext: { id: 'm1' },
      });
    });

    it('enables composer AI menu for Marine-linked inboxes', () => {
      const { captainTasksEnabled } = useCaptain();
      expect(captainTasksEnabled.value).toBe(true);
    });

    it('routes reply suggestion to Marine tasks for Marine-linked inboxes', async () => {
      MarineTasksAPI.replySuggestion.mockResolvedValue({
        data: { message: 'Marine reply', follow_up_context: { id: 'm2' } },
      });

      const { getReplySuggestion } = useCaptain();
      const result = await getReplySuggestion({});

      expect(MarineTasksAPI.replySuggestion).toHaveBeenCalledWith(
        '123',
        undefined
      );
      expect(TasksAPI.replySuggestion).not.toHaveBeenCalled();
      expect(result).toEqual({
        message: 'Marine reply',
        followUpContext: { id: 'm2' },
      });
    });

    it('routes summarize to Marine tasks for Marine-linked inboxes', async () => {
      MarineTasksAPI.summarize.mockResolvedValue({
        data: { message: 'Marine summary', follow_up_context: { id: 'm4' } },
      });

      const { summarizeConversation } = useCaptain();
      const result = await summarizeConversation({});

      expect(MarineTasksAPI.summarize).toHaveBeenCalledWith('123', undefined);
      expect(TasksAPI.summarize).not.toHaveBeenCalled();
      expect(result).toEqual({
        message: 'Marine summary',
        followUpContext: { id: 'm4' },
      });
    });

    it('translates content via Marine tasks', async () => {
      MarineTasksAPI.translate.mockResolvedValue({
        data: { message: 'Halo dunia', follow_up_context: { id: 'm3' } },
      });

      const { translateContent } = useCaptain();
      const result = await translateContent('Hello world', 'id', {});

      expect(MarineTasksAPI.translate).toHaveBeenCalledWith(
        {
          content: 'Hello world',
          targetLanguage: 'id',
          sourceLanguage: undefined,
          conversationId: '123',
        },
        undefined
      );
      expect(result).toEqual({
        message: 'Halo dunia',
        followUpContext: { id: 'm3' },
      });
    });
  });
});
