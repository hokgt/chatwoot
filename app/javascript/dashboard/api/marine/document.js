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

  create({ assistantId, name, externalLink, content } = {}) {
    return axios.post(this.url, {
      document: {
        assistant_id: assistantId,
        name,
        external_link: externalLink,
        content,
      },
    });
  }

  sync(id) {
    return axios.post(`${this.url}/${id}/sync`);
  }
}

export default new MarineDocument();
