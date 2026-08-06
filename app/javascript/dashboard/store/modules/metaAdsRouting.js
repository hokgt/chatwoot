import * as MutationHelpers from 'shared/helpers/vuex/mutationHelpers';
import MetaAdsRoutingAPI from '../../api/metaAdsRouting';
import { throwErrorMessage } from '../utils/api';

// WIJAYA_CUSTOM meta_ads_team_routing
// Self-contained Vuex module for Meta Ads -> Team routing rules. Mutation types are
// declared locally to avoid editing the shared mutation-types registry.
const types = {
  SET_UI_FLAG: 'SET_META_ADS_ROUTING_UI_FLAG',
  SET: 'SET_META_ADS_ROUTING',
  ADD: 'ADD_META_ADS_ROUTING',
  EDIT: 'EDIT_META_ADS_ROUTING',
  DELETE: 'DELETE_META_ADS_ROUTING',
};

export const state = {
  records: [],
  uiFlags: {
    isFetching: false,
    isCreating: false,
    isUpdating: false,
    isDeleting: false,
  },
};

export const getters = {
  getRoutingRules($state) {
    return $state.records;
  },
  getUIFlags($state) {
    return $state.uiFlags;
  },
};

export const actions = {
  get: async ({ commit }) => {
    commit(types.SET_UI_FLAG, { isFetching: true });
    try {
      const response = await MetaAdsRoutingAPI.get();
      commit(types.SET, response.data);
    } catch (error) {
      // Ignore error
    } finally {
      commit(types.SET_UI_FLAG, { isFetching: false });
    }
  },
  create: async ({ commit }, ruleObj) => {
    commit(types.SET_UI_FLAG, { isCreating: true });
    try {
      const response = await MetaAdsRoutingAPI.create({
        meta_ads_team_routing_rule: ruleObj,
      });
      commit(types.ADD, response.data);
    } catch (error) {
      throwErrorMessage(error);
    } finally {
      commit(types.SET_UI_FLAG, { isCreating: false });
    }
  },
  update: async ({ commit }, { id, ...updateObj }) => {
    commit(types.SET_UI_FLAG, { isUpdating: true });
    try {
      const response = await MetaAdsRoutingAPI.update(id, {
        meta_ads_team_routing_rule: updateObj,
      });
      commit(types.EDIT, response.data);
    } catch (error) {
      throwErrorMessage(error);
    } finally {
      commit(types.SET_UI_FLAG, { isUpdating: false });
    }
  },
  delete: async ({ commit }, id) => {
    commit(types.SET_UI_FLAG, { isDeleting: true });
    try {
      await MetaAdsRoutingAPI.delete(id);
      commit(types.DELETE, id);
    } catch (error) {
      throwErrorMessage(error);
    } finally {
      commit(types.SET_UI_FLAG, { isDeleting: false });
    }
  },
};

export const mutations = {
  [types.SET_UI_FLAG]($state, data) {
    $state.uiFlags = { ...$state.uiFlags, ...data };
  },
  [types.SET]: MutationHelpers.set,
  [types.ADD]: MutationHelpers.setSingleRecord,
  [types.EDIT]: MutationHelpers.update,
  [types.DELETE]: MutationHelpers.destroy,
};

export default {
  namespaced: true,
  actions,
  state,
  getters,
  mutations,
};
