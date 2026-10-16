/* global axios */
// WIJAYA_CUSTOM_START erp_lead_sidebar
import ApiClient from 'dashboard/api/ApiClient';

// Account-scoped master data for the ERP Lead "Product Requirement" Link field,
// backed by the existing ERPNext DocType "Lead Product Requirements".
//   GET  wijaya/product_requirements?q=<search>  -> { options: [{ value, label }] }
//   POST wijaya/product_requirements             -> { value, label, duplicate, message }
class WijayaErpProductRequirementsAPI extends ApiClient {
  constructor() {
    super('wijaya/product_requirements', { accountScoped: true });
  }

  list(query) {
    return axios.get(this.url, { params: query ? { q: query } : {} });
  }

  // Only product_name + raw numeric product_price are ever sent.
  create({ productName, productPrice }) {
    return axios.post(this.url, {
      product_name: productName,
      product_price: productPrice,
    });
  }
}

export default new WijayaErpProductRequirementsAPI();
// WIJAYA_CUSTOM_END erp_lead_sidebar
