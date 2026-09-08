/**
 * Meta Ads Routing settings sidebar item (Wijaya battery-owned).
 *
 * The native dashboard sidebar (app/javascript/dashboard/components-next/sidebar/Sidebar.vue)
 * contributes this single settings entry through a marker-wrapped call:
 *
 *   buildMetaAdsRoutingSidebarItem({ t, accountScopedRoute })
 *
 * The label/route/icon all live here so the native file carries only the thin
 * delegation. `t` (vue-i18n translate) and `accountScopedRoute` are injected by
 * the caller so this module stays free of any framework wiring. The label reads
 * from this battery's own i18n namespace (META_ADS_ROUTING.SIDEBAR_LABEL) rather
 * than a core settings key, keeping the string battery-owned.
 */
export function buildMetaAdsRoutingSidebarItem({ t, accountScopedRoute }) {
  return {
    name: 'Settings Meta Ads Routing',
    label: t('META_ADS_ROUTING.SIDEBAR_LABEL'),
    icon: 'i-lucide-route',
    activeOn: ['wijaya_meta_ads_routing_index'],
    to: accountScopedRoute('wijaya_meta_ads_routing_index'),
  };
}

export default buildMetaAdsRoutingSidebarItem;
