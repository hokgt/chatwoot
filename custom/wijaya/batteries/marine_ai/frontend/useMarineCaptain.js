import { computed } from 'vue';
import {
  useFunctionGetter,
  useMapGetter,
} from 'dashboard/composables/store.js';
import { useAlert } from 'dashboard/composables';
import { useI18n } from 'vue-i18n';
import { CAPTAIN_ERROR_TYPES } from 'dashboard/composables/captain/constants';
import MarineTasksAPI from '@wijaya/marine_ai/frontend/api/tasks';

/**
 * Battery-owned Captain adapter. Wraps the native Captain composable's returned
 * API. When the current conversation's inbox is linked to a Marine assistant,
 * the composer AI task methods are routed through the Marine tasks API; every
 * other conversation receives the native API completely unchanged (each method
 * delegates straight back to nativeCaptain). It also adds `translateContent`,
 * which the native Captain has no equivalent for.
 *
 * The adapter derives its own conversation/inbox/draft context so the native
 * composable stays byte-for-byte identical to upstream.
 *
 * @param {Object} nativeCaptain - The object returned by native useCaptain().
 * @returns {Object} The same API, with Marine routing layered on.
 */
export function withMarineCaptain(nativeCaptain) {
  const { t } = useI18n();
  const currentChat = useMapGetter('getSelectedChat');
  const replyMode = useMapGetter('draftMessages/getReplyEditorMode');
  const inboxGetter = useMapGetter('inboxes/getInbox');
  const conversationId = computed(() => currentChat.value?.id);
  const draftKey = computed(
    () => `draft-${conversationId.value}-${replyMode.value}`
  );
  const draftMessage = useFunctionGetter('draftMessages/get', draftKey);

  const isMarineConversation = computed(() =>
    Boolean(
      inboxGetter.value?.(currentChat.value?.inbox_id)?.marine_assistant_id
    )
  );

  const handleAPIError = error => {
    if (
      error.name === CAPTAIN_ERROR_TYPES.ABORT_ERROR ||
      error.name === CAPTAIN_ERROR_TYPES.CANCELED_ERROR
    ) {
      return;
    }
    const errorMessage =
      error.response?.data?.error ||
      t('INTEGRATION_SETTINGS.OPEN_AI.GENERATE_ERROR');
    useAlert(errorMessage);
  };

  const getErrorType = error => {
    if (
      error.name === CAPTAIN_ERROR_TYPES.ABORT_ERROR ||
      error.name === CAPTAIN_ERROR_TYPES.CANCELED_ERROR
    ) {
      return CAPTAIN_ERROR_TYPES.ABORTED;
    }
    if (error.response?.status) {
      return `${CAPTAIN_ERROR_TYPES.HTTP_PREFIX}${error.response.status}`;
    }
    return CAPTAIN_ERROR_TYPES.API_ERROR;
  };

  const unwrap = result => {
    const {
      data: { message: generatedMessage, follow_up_context: followUpContext },
    } = result;
    return { message: generatedMessage, followUpContext };
  };

  const marineRewrite = async (content, operation, options = {}) => {
    try {
      const result = await MarineTasksAPI.rewrite(
        {
          content: content || draftMessage.value,
          operation,
          conversationId: conversationId.value,
        },
        options.signal
      );
      return unwrap(result);
    } catch (error) {
      handleAPIError(error);
      return { message: '', errorType: getErrorType(error) };
    }
  };

  const marineSummarize = async (options = {}) => {
    try {
      const result = await MarineTasksAPI.summarize(
        conversationId.value,
        options.signal
      );
      return unwrap(result);
    } catch (error) {
      handleAPIError(error);
      return { message: '', errorType: getErrorType(error) };
    }
  };

  const marineReplySuggestion = async (options = {}) => {
    try {
      const result = await MarineTasksAPI.replySuggestion(
        conversationId.value,
        options.signal
      );
      return unwrap(result);
    } catch (error) {
      handleAPIError(error);
      return { message: '', errorType: getErrorType(error) };
    }
  };

  const marineFollowUp = async ({ followUpContext, message, signal }) => {
    try {
      const result = await MarineTasksAPI.followUp(
        { followUpContext, message, conversationId: conversationId.value },
        signal
      );
      const {
        data: { message: generatedMessage, follow_up_context: updatedContext },
      } = result;
      return { message: generatedMessage, followUpContext: updatedContext };
    } catch (error) {
      handleAPIError(error);
      return { message: '', followUpContext, errorType: getErrorType(error) };
    }
  };

  /**
   * Translates draft content into a target language via Marine tasks. Only
   * meaningful for Marine-linked conversations; a no-op passthrough otherwise.
   */
  const translateContent = async (content, targetLanguage, options = {}) => {
    if (!isMarineConversation.value) {
      return { message: content || draftMessage.value };
    }
    try {
      const result = await MarineTasksAPI.translate(
        {
          content: content || draftMessage.value,
          targetLanguage,
          sourceLanguage: options.sourceLanguage,
          conversationId: conversationId.value,
        },
        options.signal
      );
      return unwrap(result);
    } catch (error) {
      handleAPIError(error);
      return { message: '', errorType: getErrorType(error) };
    }
  };

  // Per-call delegation: Marine conversations use the Marine methods; every
  // other conversation falls through to the untouched native Captain method.
  const rewriteContent = (content, operation, options = {}) =>
    isMarineConversation.value
      ? marineRewrite(content, operation, options)
      : nativeCaptain.rewriteContent(content, operation, options);

  const summarizeConversation = (options = {}) =>
    isMarineConversation.value
      ? marineSummarize(options)
      : nativeCaptain.summarizeConversation(options);

  const getReplySuggestion = (options = {}) =>
    isMarineConversation.value
      ? marineReplySuggestion(options)
      : nativeCaptain.getReplySuggestion(options);

  const followUp = args =>
    isMarineConversation.value
      ? marineFollowUp(args)
      : nativeCaptain.followUp(args);

  const processEvent = async (type = 'improve', content = '', options = {}) => {
    if (!isMarineConversation.value) {
      return nativeCaptain.processEvent(type, content, options);
    }
    if (type === 'summarize') {
      return summarizeConversation(options);
    }
    if (type === 'reply_suggestion') {
      return getReplySuggestion(options);
    }
    if (type === 'translate' || type === 'translate_reply') {
      return translateContent(content, options.targetLanguage, options);
    }
    return rewriteContent(content, type, options);
  };

  const captainTasksEnabled = computed(
    () => isMarineConversation.value || nativeCaptain.captainTasksEnabled.value
  );

  return {
    ...nativeCaptain,
    captainTasksEnabled,
    rewriteContent,
    summarizeConversation,
    getReplySuggestion,
    followUp,
    processEvent,
    isMarineConversation,
    translateContent,
  };
}
