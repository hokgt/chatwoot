/* global axios */
import ApiClient from 'dashboard/api/ApiClient';

class MarineAssistant extends ApiClient {
  constructor() {
    super('marine/assistants', { accountScoped: true });
  }

  get({ page = 1, searchKey } = {}) {
    return axios.get(this.url, {
      params: {
        page,
        searchKey,
      },
    });
  }

  playground({ assistantId, messageContent, messageHistory = [], stateToken }) {
    return axios.post(`${this.url}/${assistantId}/playground`, {
      assistant: {
        message_content: messageContent,
        message_history: messageHistory,
        state_token: stateToken,
      },
    });
  }
}

export default new MarineAssistant();
