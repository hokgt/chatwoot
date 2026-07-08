/* global axios */
import ApiClient from '../ApiClient';

class MarineResponses extends ApiClient {
  constructor() {
    super('marine/assistant_responses', { accountScoped: true });
  }

  get({ assistantId, status } = {}) {
    return axios.get(this.url, {
      params: {
        assistant_id: assistantId,
        status,
      },
    });
  }
}

export default new MarineResponses();
