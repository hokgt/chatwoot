/* global axios */
import ApiClient from '../ApiClient';

class MarineDocument extends ApiClient {
  constructor() {
    super('marine/documents', { accountScoped: true });
  }

  get({ assistantId } = {}) {
    return axios.get(this.url, {
      params: {
        assistant_id: assistantId,
      },
    });
  }

  sync(id) {
    return axios.post(`${this.url}/${id}/sync`);
  }
}

export default new MarineDocument();
