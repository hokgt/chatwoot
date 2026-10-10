/* global axios */
import ApiClient from 'dashboard/api/ApiClient';

// Browser-facing client for the battery's account-scoped WhatsApp Web endpoints. It
// only ever reaches Rails (never the connector), and Rails returns only sanitized DTOs
// (no raw QR string, no secrets). Resource resolves to:
//   /api/v1/accounts/:accountId/wijaya/whatsapp_web/inboxes
class WhatsappWebInboxAPI extends ApiClient {
  constructor() {
    super('wijaya/whatsapp_web/inboxes', { accountScoped: true });
  }

  // data: { name, request_token, acknowledged }
  create(data) {
    return axios.post(this.url, data);
  }

  status(inboxId) {
    return axios.get(`${this.url}/${inboxId}`);
  }

  qr(inboxId) {
    return axios.get(`${this.url}/${inboxId}/qr`);
  }

  connect(inboxId) {
    return axios.post(`${this.url}/${inboxId}/connect`);
  }

  reconnect(inboxId) {
    return axios.post(`${this.url}/${inboxId}/reconnect`);
  }

  logout(inboxId) {
    return axios.post(`${this.url}/${inboxId}/logout`);
  }

  retry(inboxId) {
    return axios.post(`${this.url}/${inboxId}/retry`);
  }
}

export default new WhatsappWebInboxAPI();
