/* global axios */
import ApiClient from 'dashboard/api/ApiClient';

class MarineCopilotMessages extends ApiClient {
  constructor() {
    super('marine/assistants', { accountScoped: true });
  }

  get({ assistantId, threadId }) {
    return axios.get(
      `${this.url}/${assistantId}/copilot_threads/${threadId}/copilot_messages`
    );
  }

  create({ assistantId, threadId, message }) {
    return axios.post(
      `${this.url}/${assistantId}/copilot_threads/${threadId}/copilot_messages`,
      { message }
    );
  }
}

export default new MarineCopilotMessages();
