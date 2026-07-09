/* global axios */
import ApiClient from '../ApiClient';

class MarineCopilotThreads extends ApiClient {
  constructor() {
    super('marine/assistants', { accountScoped: true });
  }

  get({ assistantId } = {}) {
    return axios.get(`${this.url}/${assistantId}/copilot_threads`);
  }

  show({ assistantId, id }) {
    return axios.get(`${this.url}/${assistantId}/copilot_threads/${id}`);
  }

  create({ assistantId, message }) {
    return axios.post(`${this.url}/${assistantId}/copilot_threads`, {
      message,
    });
  }

  delete({ assistantId, id }) {
    return axios.delete(`${this.url}/${assistantId}/copilot_threads/${id}`);
  }
}

export default new MarineCopilotThreads();
