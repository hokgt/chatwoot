/* global axios */
import ApiClient from 'dashboard/api/ApiClient';

/**
 * A client for the Marine Tasks API (custom/wijaya/batteries/marine_ai).
 * Mirrors the Captain Tasks API surface so the existing composer AI actions can
 * transparently route to Marine for Marine-linked conversations.
 * @extends ApiClient
 */
class MarineTasksAPI extends ApiClient {
  constructor() {
    super('marine/tasks', { accountScoped: true });
  }

  /**
   * Rewrites content with a specific operation.
   * @param {Object} options - The rewrite options.
   * @param {string} options.content - The content to rewrite.
   * @param {string} options.operation - The rewrite operation.
   * @param {string} [options.conversationId] - The conversation ID for context.
   * @param {AbortSignal} [signal] - AbortSignal to cancel the request.
   * @returns {Promise} A promise that resolves with the rewritten content.
   */
  rewrite({ content, operation, conversationId }, signal) {
    return axios.post(
      `${this.url}/rewrite`,
      {
        content,
        operation,
        conversation_display_id: conversationId,
      },
      { signal }
    );
  }

  /**
   * Summarizes a conversation.
   * @param {string} conversationId - The conversation ID to summarize.
   * @param {AbortSignal} [signal] - AbortSignal to cancel the request.
   * @returns {Promise} A promise that resolves with the summary.
   */
  summarize(conversationId, signal) {
    return axios.post(
      `${this.url}/summarize`,
      {
        conversation_display_id: conversationId,
      },
      { signal }
    );
  }

  /**
   * Gets a reply suggestion for a conversation.
   * @param {string} conversationId - The conversation ID.
   * @param {AbortSignal} [signal] - AbortSignal to cancel the request.
   * @returns {Promise} A promise that resolves with the reply suggestion.
   */
  replySuggestion(conversationId, signal) {
    return axios.post(
      `${this.url}/reply_suggestion`,
      {
        conversation_display_id: conversationId,
      },
      { signal }
    );
  }

  /**
   * Translates content into a target language.
   * @param {Object} options - The translate options.
   * @param {string} options.content - The content to translate.
   * @param {string} options.targetLanguage - The target language code.
   * @param {string} [options.sourceLanguage] - The source language code.
   * @param {string} [options.conversationId] - The conversation ID for context.
   * @param {AbortSignal} [signal] - AbortSignal to cancel the request.
   * @returns {Promise} A promise that resolves with the translated content.
   */
  translate(
    { content, targetLanguage, sourceLanguage, conversationId },
    signal
  ) {
    return axios.post(
      `${this.url}/translate`,
      {
        content,
        target_language: targetLanguage,
        source_language: sourceLanguage,
        conversation_display_id: conversationId,
      },
      { signal }
    );
  }

  /**
   * Sends a follow-up message to continue refining a previous task result.
   * @param {Object} options - The follow-up options.
   * @param {Object} options.followUpContext - The follow-up context from a previous task.
   * @param {string} options.message - The follow-up message/request from the user.
   * @param {string} [options.conversationId] - The conversation ID for context.
   * @param {AbortSignal} [signal] - AbortSignal to cancel the request.
   * @returns {Promise} A promise that resolves with the follow-up response and updated context.
   */
  followUp({ followUpContext, message, conversationId }, signal) {
    return axios.post(
      `${this.url}/follow_up`,
      {
        follow_up_context: followUpContext,
        message,
        conversation_display_id: conversationId,
      },
      { signal }
    );
  }
}

export default new MarineTasksAPI();
