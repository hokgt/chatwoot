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

  playground({ assistantId, messageContent }) {
    return axios.post(`${this.url}/${assistantId}/playground`, {
      assistant: { message_content: messageContent },
    });
  }
}

export default new MarineAssistant();
