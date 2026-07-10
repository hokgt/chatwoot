#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

missing=0
require_file() {
  if [[ ! -f "$1" ]]; then
    echo "MISSING file: $1" >&2
    missing=1
  fi
}
require_marker() {
  local file="$1" marker="$2"
  if ! grep -q "$marker" "$file" 2>/dev/null; then
    echo "MISSING marker '$marker' in $file" >&2
    missing=1
  fi
}

require_file custom/wijaya/patches/patch_registry.yml
require_file custom/wijaya/batteries/ads_tracking/referral_parser.rb
require_file custom/wijaya/batteries/ads_tracking/hooks.rb
require_file custom/wijaya/batteries/ads_tracking/frontend/AdsReferral.vue

for file in   app/services/whatsapp/incoming_message_base_service.rb   app/builders/messages/facebook/message_builder.rb   app/builders/messages/instagram/base_message_builder.rb   lib/integrations/facebook/message_parser.rb   app/javascript/dashboard/components-next/message/Message.vue; do
  require_marker "$file" "WIJAYA_CUSTOM_START ads_tracking_ctwa_referral"
  require_marker "$file" "WIJAYA_CUSTOM_END ads_tracking_ctwa_referral"
done

require_file custom/wijaya/batteries/custom_roles/hooks.rb
require_file custom/wijaya/batteries/custom_roles/frontend/permissions.js

for file in   app/builders/agent_builder.rb   app/controllers/api/v1/accounts/agents_controller.rb   app/controllers/api/v1/accounts/bulk_actions_controller.rb   app/controllers/api/v1/accounts/conversations/assignments_controller.rb   app/controllers/api/v1/accounts/conversations/base_controller.rb   app/controllers/api/v1/accounts/conversations_controller.rb   app/finders/conversation_finder.rb   app/javascript/dashboard/helper/permissionsHelper.js   app/javascript/dashboard/routes/dashboard/settings/customRoles/Index.vue   app/javascript/dashboard/routes/dashboard/settings/customRoles/component/CustomRoleModal.vue   app/javascript/dashboard/routes/dashboard/settings/customRoles/customRole.routes.js   app/models/account_user.rb   app/services/conversations/permission_filter_service.rb   enterprise/app/models/custom_role.rb   enterprise/app/models/enterprise/account_user.rb   enterprise/app/policies/enterprise/conversation_policy.rb   enterprise/app/services/enterprise/conversations/permission_filter_service.rb; do
  require_marker "$file" "WIJAYA_CUSTOM_START custom_roles_rbac"
  require_marker "$file" "WIJAYA_CUSTOM_END custom_roles_rbac"
done

# meta_ads_team_routing
require_file custom/wijaya/batteries/meta_ads_team_routing/routing_rule.rb
require_file custom/wijaya/batteries/meta_ads_team_routing/routing_service.rb
require_file custom/wijaya/batteries/meta_ads_team_routing/hooks.rb
require_file app/controllers/api/v1/accounts/wijaya/meta_ads_team_routing_rules_controller.rb
require_file app/javascript/dashboard/api/metaAdsRouting.js
require_file app/javascript/dashboard/store/modules/metaAdsRouting.js
require_file app/javascript/dashboard/routes/dashboard/settings/wijaya/wijaya.routes.js
require_file app/javascript/dashboard/routes/dashboard/settings/wijaya/Index.vue
require_file app/javascript/dashboard/routes/dashboard/settings/wijaya/RoutingRuleModal.vue
require_file app/javascript/dashboard/i18n/locale/en/wijayaMetaAdsRouting.json

for file in \
  app/services/whatsapp/incoming_message_base_service.rb \
  app/builders/messages/facebook/message_builder.rb \
  app/builders/messages/instagram/base_message_builder.rb \
  config/initializers/wijaya_meta_ads_team_routing.rb \
  config/routes.rb \
  app/javascript/dashboard/components-next/sidebar/Sidebar.vue; do
  require_marker "$file" "WIJAYA_CUSTOM_START meta_ads_team_routing"
  require_marker "$file" "WIJAYA_CUSTOM_END meta_ads_team_routing"
done

for file in \
  app/javascript/dashboard/store/index.js \
  app/javascript/dashboard/routes/dashboard/settings/settings.routes.js \
  app/javascript/dashboard/i18n/locale/en/index.js; do
  require_marker "$file" "WIJAYA_CUSTOM meta_ads_team_routing"
done


# erp_lead_sidebar
require_file custom/wijaya/batteries/erp_lead_sidebar/config.rb
require_file custom/wijaya/batteries/erp_lead_sidebar/lead_draft.rb
require_file custom/wijaya/batteries/erp_lead_sidebar/payload_builder.rb
require_file custom/wijaya/batteries/erp_lead_sidebar/sync_service.rb
require_file custom/wijaya/batteries/erp_lead_sidebar/refresh_service.rb
require_file custom/wijaya/batteries/erp_lead_sidebar/options_service.rb
require_file custom/wijaya/batteries/erp_lead_sidebar/frontend/ErpLeadPanel.vue
require_file custom/wijaya/batteries/erp_lead_sidebar/frontend/fieldConfig.js
require_file custom/wijaya/batteries/erp_lead_sidebar/frontend/mappings.js
require_file app/controllers/api/v1/accounts/wijaya/erp_lead_drafts_controller.rb
require_file app/javascript/dashboard/api/wijayaErpLeadDrafts.js
require_file db/migrate/20260706000000_create_wijaya_erp_lead_drafts.rb

for file in \
  config/initializers/wijaya_erp_lead_sidebar.rb \
  config/routes.rb \
  app/javascript/dashboard/routes/dashboard/conversation/ContactPanel.vue; do
  require_marker "$file" "WIJAYA_CUSTOM_START erp_lead_sidebar"
  require_marker "$file" "WIJAYA_CUSTOM_END erp_lead_sidebar"
done

# enterprise_extension_compat
require_marker "config/initializers/01_inject_enterprise_edition_module.rb" "WIJAYA_CUSTOM_START enterprise_extension_compat"
require_marker "config/initializers/01_inject_enterprise_edition_module.rb" "WIJAYA_CUSTOM_END enterprise_extension_compat"

# development_version
require_file custom/wijaya/batteries/development_version/version.yml
require_file custom/wijaya/batteries/development_version/CHANGELOG.md
require_file custom/wijaya/batteries/development_version/hooks.rb
require_file custom/wijaya/batteries/development_version/scripts/bump_version.rb
require_file custom/wijaya/batteries/development_version/README.md

for file in \
  app/controllers/dashboard_controller.rb \
  app/javascript/shared/store/globalConfig.js \
  app/javascript/dashboard/routes/dashboard/settings/account/components/BuildInfo.vue; do
  require_marker "$file" "WIJAYA_CUSTOM_START development_version"
  require_marker "$file" "WIJAYA_CUSTOM_END development_version"
done

# marine_ai
require_file custom/wijaya/marine/loader.rb
require_file custom/wijaya/marine/app/models/marine/assistant.rb
require_file custom/wijaya/marine/app/models/marine/document.rb
require_file custom/wijaya/marine/app/models/marine/assistant_response.rb
require_file custom/wijaya/marine/app/models/marine_inbox.rb
require_file custom/wijaya/marine/app/models/concerns/wijaya/marine/account_extensions.rb
require_file custom/wijaya/marine/app/models/concerns/wijaya/marine/inbox_extensions.rb
require_file custom/wijaya/marine/app/services/wijaya/marine/hooks.rb
require_file custom/wijaya/marine/app/services/marine/cell/knowledge_base_service.rb
require_file custom/wijaya/marine/app/services/marine/cell/retriever.rb
require_file custom/wijaya/marine/app/services/marine/cell/retrieval_result.rb
require_file custom/wijaya/marine/app/services/marine/cell/citation_builder.rb
require_file custom/wijaya/marine/app/services/marine/charge/response_generator.rb
require_file custom/wijaya/marine/app/services/marine/charge/confidence_scorer.rb
require_file custom/wijaya/marine/app/services/marine/circuit/handoff_service.rb
require_file custom/wijaya/marine/app/services/marine/llm/assistant_chat_service.rb
require_file custom/wijaya/marine/app/services/marine/llm/embedding_service.rb
require_file custom/wijaya/marine/app/services/marine/llm/config.rb
require_file custom/wijaya/marine/app/services/marine/llm/base_service.rb
require_file custom/wijaya/marine/app/services/marine/llm/prompt_renderer.rb
require_file custom/wijaya/marine/app/services/marine/llm/json_response_parser.rb
require_file custom/wijaya/marine/app/services/marine/llm/language_detector.rb
require_file custom/wijaya/marine/app/services/marine/llm/translate_query_service.rb
require_file custom/wijaya/marine/app/services/marine/llm/translate_response_service.rb
require_file custom/wijaya/marine/app/jobs/marine/conversation/response_builder_job.rb
require_file custom/wijaya/marine/app/jobs/marine/documents/response_builder_job.rb
require_file custom/wijaya/marine/app/jobs/marine/llm/update_embedding_job.rb
require_file custom/wijaya/marine/app/policies/marine/assistant_policy.rb
require_file custom/wijaya/marine/app/policies/marine/tasks_policy.rb
require_file custom/wijaya/marine/app/services/marine/copilot/base_service.rb
require_file custom/wijaya/marine/app/services/marine/copilot/conversation_context_builder.rb
require_file custom/wijaya/marine/app/services/marine/copilot/reply_suggestion_service.rb
require_file custom/wijaya/marine/app/services/marine/copilot/summary_service.rb
require_file custom/wijaya/marine/app/services/marine/copilot/rewrite_service.rb
require_file custom/wijaya/marine/app/services/marine/copilot/translate_service.rb
require_file custom/wijaya/marine/app/services/marine/copilot/follow_up_service.rb
require_file custom/wijaya/marine/app/services/marine/memory/contact_notes_service.rb
require_file custom/wijaya/marine/app/jobs/marine/memory/generate_contact_notes_job.rb
require_file custom/wijaya/marine/app/controllers/api/v1/accounts/marine/tasks_controller.rb
require_file custom/wijaya/marine/app/controllers/api/v1/accounts/marine/assistants_controller.rb
require_file custom/wijaya/marine/app/controllers/api/v1/accounts/marine/documents_controller.rb
require_file custom/wijaya/marine/app/controllers/api/v1/accounts/marine/assistant_responses_controller.rb
require_file custom/wijaya/marine/app/controllers/api/v1/accounts/marine/inboxes_controller.rb
require_file custom/wijaya/marine/app/controllers/api/v1/accounts/marine/preferences_controller.rb
require_file custom/wijaya/marine/app/models/marine/copilot_thread.rb
require_file custom/wijaya/marine/app/models/marine/copilot_message.rb
require_file custom/wijaya/marine/app/services/marine/copilot/search_base_service.rb
require_file custom/wijaya/marine/app/services/marine/copilot/search_conversations_service.rb
require_file custom/wijaya/marine/app/services/marine/copilot/get_conversation_service.rb
require_file custom/wijaya/marine/app/services/marine/copilot/search_contacts_service.rb
require_file custom/wijaya/marine/app/services/marine/copilot/get_contact_service.rb
require_file custom/wijaya/marine/app/services/marine/copilot/query_service.rb
require_file custom/wijaya/marine/app/services/marine/agent/scenario_selector.rb
require_file custom/wijaya/marine/app/services/marine/agent/runner.rb
require_file custom/wijaya/marine/app/controllers/api/v1/accounts/marine/copilot_threads_controller.rb
require_file custom/wijaya/marine/app/controllers/api/v1/accounts/marine/copilot_messages_controller.rb
require_file custom/wijaya/marine/app/policies/marine/copilot_thread_policy.rb
require_file custom/wijaya/marine/app/policies/marine/copilot_message_policy.rb
require_file db/migrate/20260708010000_create_wijaya_marine_tables.rb
require_file db/migrate/20260708010001_create_wijaya_marine_inboxes.rb
require_file db/migrate/20260709030000_create_marine_copilot_tables.rb
require_file app/javascript/dashboard/api/marine/copilotThreads.js
require_file app/javascript/dashboard/api/marine/copilotMessages.js
require_file app/javascript/dashboard/routes/dashboard/marine/copilot/Index.vue
require_file app/javascript/dashboard/api/marine/tasks.js
require_file app/javascript/dashboard/api/marine/assistant.js
require_file app/javascript/dashboard/api/marine/response.js
require_file app/javascript/dashboard/api/marine/document.js
require_file app/javascript/dashboard/api/marine/inboxes.js
require_file app/javascript/dashboard/api/marine/preferences.js
require_file app/javascript/dashboard/routes/dashboard/marine/Index.vue
require_file app/javascript/dashboard/routes/dashboard/marine/marine.routes.js
require_file app/javascript/dashboard/routes/dashboard/marine/pages/AssistantsIndexPage.vue
require_file app/javascript/dashboard/routes/dashboard/marine/composables/useMarineAssistants.js
require_file app/javascript/dashboard/routes/dashboard/marine/components/MarinePageShell.vue
require_file app/javascript/dashboard/routes/dashboard/marine/components/MarinePageLayout.vue
require_file app/javascript/dashboard/routes/dashboard/marine/components/MarineSettingsHeader.vue
require_file app/javascript/dashboard/routes/dashboard/marine/components/MarineAssistantBasicSettingsForm.vue
require_file app/javascript/dashboard/routes/dashboard/marine/components/MarineAssistantSystemSettingsForm.vue
require_file app/javascript/dashboard/routes/dashboard/marine/components/MarineAssistantControlItems.vue
require_file app/javascript/dashboard/routes/dashboard/marine/components/MarineDeleteDialog.vue
require_file app/javascript/dashboard/routes/dashboard/marine/components/MarineAssistantPlayground.vue
require_file app/javascript/dashboard/routes/dashboard/marine/components/MarineMessageList.vue
require_file app/javascript/dashboard/routes/dashboard/marine/components/MarineAssistantSwitcher.vue
require_file app/javascript/dashboard/routes/dashboard/marine/components/MarineDocumentCard.vue
require_file app/javascript/dashboard/routes/dashboard/marine/components/CreateDocumentDialog.vue
require_file app/javascript/dashboard/routes/dashboard/marine/components/DocumentPageEmptyState.vue
require_file app/javascript/dashboard/routes/dashboard/marine/components/MarineResponseCard.vue
require_file app/javascript/dashboard/routes/dashboard/marine/components/CreateResponseDialog.vue
require_file app/javascript/dashboard/routes/dashboard/marine/components/ResponsePageEmptyState.vue
require_file app/javascript/dashboard/routes/dashboard/marine/components/MarineInboxCard.vue
require_file app/javascript/dashboard/routes/dashboard/marine/components/ConnectInboxDialog.vue
require_file app/javascript/dashboard/routes/dashboard/marine/components/InboxPageEmptyState.vue
require_file app/javascript/dashboard/routes/dashboard/marine/responses/Index.vue
require_file app/javascript/dashboard/routes/dashboard/marine/documents/Index.vue
require_file app/javascript/dashboard/routes/dashboard/marine/scenarios/Index.vue
require_file app/javascript/dashboard/routes/dashboard/marine/playground/Index.vue
require_file app/javascript/dashboard/routes/dashboard/marine/inboxes/Index.vue
require_file app/javascript/dashboard/routes/dashboard/marine/tools/Index.vue
require_file app/javascript/dashboard/routes/dashboard/marine/settings/Index.vue
require_file app/javascript/dashboard/routes/dashboard/settings/marine/Index.vue
require_file app/javascript/dashboard/routes/dashboard/settings/marine/marine.routes.js
require_file app/javascript/dashboard/i18n/locale/en/marine.json

for file in \
  config/initializers/wijaya_marine_ai.rb \
  config/routes.rb \
  config/installation_config.yml \
  app/controllers/super_admin/app_configs_controller.rb \
  app/services/message_templates/hook_execution_service.rb \
  app/models/conversation.rb \
  app/views/api/v1/models/_inbox.json.jbuilder \
  app/javascript/dashboard/routes/dashboard/dashboard.routes.js \
  app/javascript/dashboard/routes/dashboard/settings/settings.routes.js \
  app/javascript/dashboard/composables/useCaptain.js \
  app/javascript/dashboard/components/widgets/WootWriter/CopilotMenuBar.vue \
  app/javascript/dashboard/components-next/sidebar/Sidebar.vue \
  app/javascript/dashboard/i18n/locale/en/index.js; do
  require_marker "$file" "WIJAYA_CUSTOM_START marine_ai"
  require_marker "$file" "WIJAYA_CUSTOM_END marine_ai"
done

if [[ "$missing" -ne 0 ]]; then
  exit 1
fi

echo "Wijaya custom patches OK"
