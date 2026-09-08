/* global axios */
import ApiClient from 'dashboard/api/ApiClient';

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

  create({ assistantId, question, answer, status = 'approved' } = {}) {
    return axios.post(this.url, {
      assistant_response: {
        assistant_id: assistantId,
        question,
        answer,
        status,
      },
    });
  }

  update(id, { question, answer, status } = {}) {
    return axios.patch(`${this.url}/${id}`, {
      assistant_response: { question, answer, status },
    });
  }

  approve(id) {
    return this.update(id, { status: 'approved' });
  }

  delete(id) {
    return axios.delete(`${this.url}/${id}`);
  }
}

export default new MarineResponses();
