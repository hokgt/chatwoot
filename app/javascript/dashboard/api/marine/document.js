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

  // Bounded, read-only product-family lookup for the catalog picker. Returns
  // { payload: [{ code, name }] }; never mutates any document state.
  productFamilies({ query = '', limit } = {}) {
    return axios.get(`${this.url}/product_families`, {
      params: { query, limit },
    });
  }

  // Flat multipart create/replace of the single primary Product Catalog for an
  // assistant + product family. Always primary_catalog=true; `replace` is false on the
  // first attempt and only retried as true after the user confirms the 409 conflict.
  createProductCatalog({
    assistantId,
    productFamilyCode,
    name,
    file,
    replace = false,
  } = {}) {
    const formData = new FormData();
    formData.append('assistant_id', assistantId);
    formData.append('product_family_code', productFamilyCode);
    if (name) formData.append('name', name);
    formData.append('primary_catalog', 'true');
    formData.append('replace', replace ? 'true' : 'false');
    formData.append('file', file);
    return axios.post(`${this.url}/product_catalog`, formData);
  }

  sync(id) {
    return axios.post(`${this.url}/${id}/sync`);
  }

  delete(id) {
    return axios.delete(`${this.url}/${id}`);
  }
}

export default new MarineDocument();
