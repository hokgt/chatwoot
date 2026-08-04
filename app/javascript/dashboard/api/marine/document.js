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

  // Website documents post a JSON `document` payload. SOP uploads pass a prebuilt
  // FormData (nested `document[...]` keys incl. the file) which is forwarded as-is so
  // axios can set the correct multipart boundary — never override the content type here.
  create(payload = {}) {
    if (payload instanceof FormData) {
      return axios.post(this.url, payload);
    }
    const { assistantId, name, externalLink, content } = payload;
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

  delete(id) {
    return axios.delete(`${this.url}/${id}`);
  }
}

export default new MarineDocument();
