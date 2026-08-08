/**
 * ERPNext Settings sidebar item (Wijaya battery-owned).
 *
 * The native dashboard sidebar (app/javascript/dashboard/components-next/sidebar/Sidebar.vue)
 * contributes this single settings entry through a marker-wrapped call:
 *
 *   buildErpSettingsSidebarItem({ t, accountScopedRoute })
 *
 * The label/route/icon all live here so the native file carries only the thin
 * delegation. `t` (vue-i18n translate) and `accountScopedRoute` are injected by
 * the caller so this module stays free of any framework wiring. The label reads
 * from this battery's own i18n namespace (WIJAYA_ERP_SETTINGS.SIDEBAR_LABEL)
 * rather than a core settings key, keeping the string battery-owned.
 */
export function buildErpSettingsSidebarItem({ t, accountScopedRoute }) {
  return {
    name: 'Settings ERPNext',
    label: t('WIJAYA_ERP_SETTINGS.SIDEBAR_LABEL'),
    icon: 'i-lucide-plug',
    activeOn: ['wijaya_erp_settings_index'],
    to: accountScopedRoute('wijaya_erp_settings_index'),
  };
}

export default buildErpSettingsSidebarItem;
