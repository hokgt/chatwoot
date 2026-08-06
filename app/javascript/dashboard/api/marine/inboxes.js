/* global axios */
import ApiClient from '../ApiClient';

class MarineInboxes extends ApiClient {
  constructor() {
    super('marine/assistants', { accountScoped: true });
  }

  get({ assistantId } = {}) {
    return axios.get(`${this.url}/${assistantId}/inboxes`);
  }

  create({ assistantId, inboxId } = {}) {
    return axios.post(`${this.url}/${assistantId}/inboxes`, {
      inbox: { inbox_id: inboxId },
    });
  }

  delete({ assistantId, inboxId } = {}) {
    return axios.delete(`${this.url}/${assistantId}/inboxes/${inboxId}`);
  }
}

export default new MarineInboxes();
