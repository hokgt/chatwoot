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

# wijaya_core: single generic initializer + generic battery loader replace all the
# per-feature config/initializers/wijaya_*.rb files. Each feature battery ships its
# own loader.rb and self-registers with the core loader.
require_file custom/wijaya/batteries/core/loader.rb
require_file config/initializers/wijaya.rb
require_marker config/initializers/wijaya.rb "WIJAYA_CUSTOM_START core"
require_marker config/initializers/wijaya.rb "WIJAYA_CUSTOM_END core"
# The retired per-feature initializers must be fully gone (behavior now lives in the
# generic loader + each battery loader.rb).
for legacy_init in \
  config/initializers/wijaya_marine_ai.rb \
  config/initializers/wijaya_erp_lead_sidebar.rb \
  config/initializers/wijaya_meta_ads_team_routing.rb; do
  if [[ -f "$legacy_init" ]]; then
    echo "FORBIDDEN: retired per-feature initializer '$legacy_init' still exists (fold it into the battery loader + generic config/initializers/wijaya.rb)" >&2
    missing=1
  fi
done

# wijaya_core hooks + routes: the generic fail-open hook dispatcher and the single
# route registrar. All Wijaya endpoints are drawn by one consolidated marker call in
# config/routes.rb (replacing the retired per-feature marine_ai/meta_ads/erp route
# blocks); the registrar owns every endpoint definition and fails open on any error.
require_file custom/wijaya/batteries/core/hooks.rb
require_file custom/wijaya/batteries/core/routes.rb
require_file custom/wijaya/batteries/HOOKS.md
require_file spec/custom/wijaya/batteries/core/hooks_spec.rb
require_marker config/routes.rb "WIJAYA_CUSTOM_START wijaya_routes"
require_marker config/routes.rb "WIJAYA_CUSTOM_END wijaya_routes"
# Per-battery route modules: core/routes.rb owns only generic orchestration and
# requires+draws each of these in an isolated, fail-open block.
require_file custom/wijaya/batteries/marine_ai/routes.rb
require_file custom/wijaya/batteries/meta_ads_team_routing/routes.rb
require_file custom/wijaya/batteries/erp_lead_sidebar/routes.rb

# Thin-adapter guard: the native files that hand off to a Wijaya battery must keep
# their marker blocks small and free of feature business logic (API selection,
# task calls, brand labels). This protects the core/battery boundary from
# regressing back into inline feature logic.
assert_thin_marker_blocks() {
  local file="$1" feature="$2" max_lines="$3"
  [[ -f "$file" ]] || return 0
  awk -v feat="$feature" -v maxl="$max_lines" -v file="$file" '
    $0 ~ ("WIJAYA_CUSTOM_START " feat "$") { inblock=1; n=0; next }
    $0 ~ ("WIJAYA_CUSTOM_END " feat "$") {
      if (n > maxl) { print "OVERSIZED marker block (" n " lines > " maxl ") for " feat " in " file > "/dev/stderr"; rc=1 }
      inblock=0; next
    }
    inblock {
      n++
      if ($0 ~ /resolveTasksApi|MarineTasksAPI|\.rewrite\(|\.translate\(|\.summarize\(|\.replySuggestion\(|\.followUp\(|Wijaya Dev v|isMarineConversation \?|marine_assistant_id/) {
        print "FORBIDDEN business logic in marker block for " feat " in " file ": " $0 > "/dev/stderr"; rc=1
      }
    }
    END { exit (rc ? 1 : 0) }
  ' "$file" || missing=1
}
assert_thin_marker_blocks app/javascript/dashboard/composables/useCaptain.js marine_ai 8
assert_thin_marker_blocks app/javascript/dashboard/components/widgets/WootWriter/CopilotMenuBar.vue marine_ai 8
assert_thin_marker_blocks app/javascript/dashboard/components/widgets/WootWriter/ReplyTopPanel.vue marine_ai 8
assert_thin_marker_blocks app/javascript/dashboard/routes/dashboard/settings/account/components/BuildInfo.vue development_version 8

require_file custom/wijaya/batteries/ads_tracking/referral_parser.rb
require_file custom/wijaya/batteries/ads_tracking/hooks.rb
require_file custom/wijaya/batteries/ads_tracking/frontend/AdsReferral.vue

for file in   app/services/whatsapp/incoming_message_base_service.rb   app/builders/messages/facebook/message_builder.rb   app/builders/messages/instagram/base_message_builder.rb   lib/integrations/facebook/message_parser.rb   app/javascript/dashboard/components-next/message/Message.vue; do
  require_marker "$file" "WIJAYA_CUSTOM_START ads_tracking_ctwa_referral"
  require_marker "$file" "WIJAYA_CUSTOM_END ads_tracking_ctwa_referral"
done

require_file custom/wijaya/batteries/custom_roles/hooks.rb
require_file custom/wijaya/batteries/custom_roles/frontend/permissions.js

for file in   app/builders/agent_builder.rb   app/controllers/api/v1/accounts/agents_controller.rb   app/controllers/api/v1/accounts/bulk_actions_controller.rb   app/controllers/api/v1/accounts/conversations/assignments_controller.rb   app/controllers/api/v1/accounts/conversations/base_controller.rb   app/controllers/api/v1/accounts/conversations_controller.rb   app/finders/conversation_finder.rb   app/javascript/dashboard/helper/permissionsHelper.js   app/javascript/dashboard/store/modules/conversations/helpers.js   app/javascript/dashboard/store/modules/customRole.js   app/javascript/dashboard/routes/dashboard/settings/customRoles/Index.vue   app/javascript/dashboard/routes/dashboard/settings/customRoles/component/CustomRoleModal.vue   app/javascript/dashboard/routes/dashboard/settings/customRoles/customRole.routes.js   app/models/account_user.rb   app/services/conversations/permission_filter_service.rb   enterprise/app/controllers/enterprise/api/v1/accounts/agents_controller.rb   enterprise/app/models/custom_role.rb   enterprise/app/models/enterprise/account_user.rb   enterprise/app/policies/enterprise/conversation_policy.rb   enterprise/app/services/enterprise/conversations/permission_filter_service.rb; do
  require_marker "$file" "WIJAYA_CUSTOM_START custom_roles_rbac"
  require_marker "$file" "WIJAYA_CUSTOM_END custom_roles_rbac"
done

# meta_ads_team_routing
require_file custom/wijaya/batteries/meta_ads_team_routing/routing_rule.rb
require_file custom/wijaya/batteries/meta_ads_team_routing/routing_service.rb
require_file custom/wijaya/batteries/meta_ads_team_routing/hooks.rb
require_file custom/wijaya/batteries/meta_ads_team_routing/app/controllers/api/v1/accounts/wijaya/meta_ads_team_routing_rules_controller.rb
require_file custom/wijaya/batteries/meta_ads_team_routing/frontend/api/metaAdsRouting.js
require_file custom/wijaya/batteries/meta_ads_team_routing/frontend/store/metaAdsRouting.js
require_file custom/wijaya/batteries/meta_ads_team_routing/frontend/routes/wijaya.routes.js
require_file custom/wijaya/batteries/meta_ads_team_routing/frontend/routes/Index.vue
require_file custom/wijaya/batteries/meta_ads_team_routing/frontend/routes/RoutingRuleModal.vue
require_file custom/wijaya/batteries/meta_ads_team_routing/frontend/i18n/wijayaMetaAdsRouting.json
require_file custom/wijaya/batteries/meta_ads_team_routing/frontend/sidebar/metaAdsRoutingSidebarItem.js
require_file custom/wijaya/batteries/meta_ads_team_routing/loader.rb
require_file spec/custom/wijaya/meta_ads_team_routing/team_routing_dispatch_spec.rb

for file in \
  app/services/whatsapp/incoming_message_base_service.rb \
  app/builders/messages/facebook/message_builder.rb \
  app/builders/messages/instagram/base_message_builder.rb \
  app/javascript/dashboard/components-next/sidebar/Sidebar.vue \
  app/javascript/dashboard/store/index.js \
  app/javascript/dashboard/routes/dashboard/settings/settings.routes.js \
  app/javascript/dashboard/i18n/locale/en/index.js; do
  require_marker "$file" "WIJAYA_CUSTOM_START meta_ads_team_routing"
  require_marker "$file" "WIJAYA_CUSTOM_END meta_ads_team_routing"
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
require_file custom/wijaya/batteries/erp_lead_sidebar/app/controllers/api/v1/accounts/wijaya/erp_lead_drafts_controller.rb
require_file custom/wijaya/batteries/erp_lead_sidebar/frontend/api/wijayaErpLeadDrafts.js
# ERP has_one association attached to Conversation via a battery concern (loader to_prepare).
require_file custom/wijaya/batteries/erp_lead_sidebar/conversation_extensions.rb
require_file custom/wijaya/batteries/erp_lead_sidebar/loader.rb
require_file db/migrate/20260706000000_create_wijaya_erp_lead_drafts.rb

for file in \
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

# Build label is rendered by a Battery Vue component; the native shared global
# config store no longer carries the Wijaya dev field (restored to upstream).
require_file custom/wijaya/batteries/development_version/frontend/BuildVersion.vue

for file in \
  app/controllers/dashboard_controller.rb \
  app/javascript/dashboard/routes/dashboard/settings/account/components/BuildInfo.vue; do
  require_marker "$file" "WIJAYA_CUSTOM_START development_version"
  require_marker "$file" "WIJAYA_CUSTOM_END development_version"
done

# test_database_safety
require_file custom/wijaya/batteries/test_database_safety/guard.rb
require_file custom/wijaya/batteries/test_database_safety/bin/run_test_specs.sh
require_marker "config/database.yml" "WIJAYA_CUSTOM_START test_database_safety"
require_marker "config/database.yml" "WIJAYA_CUSTOM_END test_database_safety"

# marine_ai
# Legacy Marine tree relocation guard: the pre-battery path (custom/wijaya/<marine>)
# must be fully gone and unreferenced now that Marine lives under the marine_ai battery.
# The needle is assembled at runtime so this checker never literally embeds the legacy
# path (prevents a false self-match in the reference scan below).
legacy_marine_root="custom/wijaya/mar""ine"
if [[ -d "$legacy_marine_root" || -d "spec/$legacy_marine_root" ]]; then
  echo "FORBIDDEN: legacy Marine tree '$legacy_marine_root' still exists (must live under custom/wijaya/batteries/marine_ai)" >&2
  missing=1
fi
if git grep -qI --untracked "$legacy_marine_root" 2>/dev/null; then
  echo "FORBIDDEN: legacy path '$legacy_marine_root' is still referenced (relocate all refs to custom/wijaya/batteries/marine_ai)" >&2
  missing=1
fi
require_file custom/wijaya/batteries/marine_ai/loader.rb
# Config ownership: Marine settings and locale are owned by the battery. The core
# config must not seed MARINE_* keys, allowlist them in super admin, or carry the
# Marine backend locale — those defaults/keys now live in the battery.
require_file custom/wijaya/batteries/marine_ai/config/locales/en.yml
require_marker custom/wijaya/batteries/marine_ai/config/locales/en.yml "slug_generation_failed"
require_marker custom/wijaya/batteries/marine_ai/loader.rb "register_locales!"
if grep -q "MARINE_" config/installation_config.yml 2>/dev/null; then
  echo "FORBIDDEN: config/installation_config.yml still seeds MARINE_* keys (battery owns them via first_or_initialize)" >&2
  missing=1
fi
if grep -qE "^  marine:" config/locales/en.yml 2>/dev/null; then
  echo "FORBIDDEN: config/locales/en.yml still defines the top-level Marine locale (moved to the marine_ai battery)" >&2
  missing=1
fi
if grep -q "'marine'" app/controllers/super_admin/app_configs_controller.rb 2>/dev/null; then
  echo "FORBIDDEN: super_admin app_configs_controller.rb still carries the Marine allowlist (battery owns Marine settings)" >&2
  missing=1
fi
require_file custom/wijaya/batteries/marine_ai/app/models/marine/assistant.rb
require_file custom/wijaya/batteries/marine_ai/app/models/marine/document.rb
require_file custom/wijaya/batteries/marine_ai/app/models/marine/assistant_response.rb
require_file custom/wijaya/batteries/marine_ai/app/models/marine_inbox.rb
require_file custom/wijaya/batteries/marine_ai/app/models/concerns/wijaya/marine/account_extensions.rb
require_file custom/wijaya/batteries/marine_ai/app/models/concerns/wijaya/marine/inbox_extensions.rb
# Marine resolved-conversation callback attached to Conversation via a battery concern.
require_file custom/wijaya/batteries/marine_ai/app/models/concerns/wijaya/marine/conversation_extensions.rb
require_file custom/wijaya/batteries/marine_ai/app/services/wijaya/marine/hooks.rb
require_file custom/wijaya/batteries/marine_ai/app/services/marine/cell/knowledge_base_service.rb
require_file custom/wijaya/batteries/marine_ai/app/services/marine/cell/retriever.rb
require_file custom/wijaya/batteries/marine_ai/app/services/marine/cell/retrieval_result.rb
require_file custom/wijaya/batteries/marine_ai/app/services/marine/cell/citation_builder.rb
require_file custom/wijaya/batteries/marine_ai/app/services/marine/charge/response_generator.rb
require_file custom/wijaya/batteries/marine_ai/app/services/marine/charge/confidence_scorer.rb
require_file custom/wijaya/batteries/marine_ai/app/services/marine/circuit/handoff_service.rb
require_file custom/wijaya/batteries/marine_ai/app/services/marine/llm/assistant_chat_service.rb
require_file custom/wijaya/batteries/marine_ai/app/services/marine/llm/embedding_service.rb
require_file custom/wijaya/batteries/marine_ai/app/services/marine/llm/config.rb
require_file custom/wijaya/batteries/marine_ai/app/services/marine/llm/provider_config.rb
require_file custom/wijaya/batteries/marine_ai/app/services/marine/llm/connection_test_service.rb
require_file custom/wijaya/batteries/marine_ai/app/services/marine/llm/base_service.rb
require_file custom/wijaya/batteries/marine_ai/app/services/marine/llm/prompt_renderer.rb
require_file custom/wijaya/batteries/marine_ai/app/services/marine/llm/json_response_parser.rb
require_file custom/wijaya/batteries/marine_ai/app/services/marine/llm/language_detector.rb
require_file custom/wijaya/batteries/marine_ai/app/services/marine/llm/translate_query_service.rb
require_file custom/wijaya/batteries/marine_ai/app/services/marine/llm/translate_response_service.rb
require_file custom/wijaya/batteries/marine_ai/app/jobs/marine/conversation/response_builder_job.rb
require_file custom/wijaya/batteries/marine_ai/app/jobs/marine/documents/response_builder_job.rb
require_file custom/wijaya/batteries/marine_ai/app/jobs/marine/llm/update_embedding_job.rb
require_file custom/wijaya/batteries/marine_ai/app/policies/marine/assistant_policy.rb
require_file custom/wijaya/batteries/marine_ai/app/policies/marine/tasks_policy.rb
require_file custom/wijaya/batteries/marine_ai/app/services/marine/copilot/base_service.rb
require_file custom/wijaya/batteries/marine_ai/app/services/marine/copilot/conversation_context_builder.rb
require_file custom/wijaya/batteries/marine_ai/app/services/marine/copilot/reply_suggestion_service.rb
require_file custom/wijaya/batteries/marine_ai/app/services/marine/copilot/summary_service.rb
require_file custom/wijaya/batteries/marine_ai/app/services/marine/copilot/rewrite_service.rb
require_file custom/wijaya/batteries/marine_ai/app/services/marine/copilot/translate_service.rb
require_file custom/wijaya/batteries/marine_ai/app/services/marine/copilot/follow_up_service.rb
require_file custom/wijaya/batteries/marine_ai/app/services/marine/memory/contact_notes_service.rb
require_file custom/wijaya/batteries/marine_ai/app/jobs/marine/memory/generate_contact_notes_job.rb
require_file custom/wijaya/batteries/marine_ai/app/controllers/api/v1/accounts/marine/tasks_controller.rb
require_file custom/wijaya/batteries/marine_ai/app/controllers/api/v1/accounts/marine/assistants_controller.rb
require_file custom/wijaya/batteries/marine_ai/app/controllers/api/v1/accounts/marine/documents_controller.rb
# Commit 1B — Product Catalog backend
require_file custom/wijaya/batteries/marine_ai/app/services/marine/documents/errors.rb
require_file custom/wijaya/batteries/marine_ai/app/services/marine/documents/upload_validator.rb
require_file custom/wijaya/batteries/marine_ai/app/services/marine/documents/serializer.rb
require_file custom/wijaya/batteries/marine_ai/app/services/marine/documents/product_catalog_service.rb
require_file custom/wijaya/batteries/marine_ai/app/services/marine/catalog/errors.rb
require_file custom/wijaya/batteries/marine_ai/app/services/marine/catalog/config.rb
require_file custom/wijaya/batteries/marine_ai/app/services/marine/catalog/connection.rb
require_file custom/wijaya/batteries/marine_ai/app/services/marine/catalog/product_family_repository.rb
require_file custom/wijaya/batteries/marine_ai/app/models/concerns/wijaya/marine/active_storage_analysis_guard.rb
require_file custom/wijaya/batteries/marine_ai/docs/product_catalog_db.md
# Commit 1C — SOP extraction + OCR foundation
require_file custom/wijaya/batteries/marine_ai/app/services/marine/documents/command_runner.rb
require_file custom/wijaya/batteries/marine_ai/app/services/marine/documents/create_sop_service.rb
require_file custom/wijaya/batteries/marine_ai/app/services/marine/documents/sop/extraction_service.rb
require_file custom/wijaya/batteries/marine_ai/app/services/marine/documents/sop/pdf_extractor.rb
require_file custom/wijaya/batteries/marine_ai/app/services/marine/documents/sop/image_ocr_service.rb
require_file custom/wijaya/batteries/marine_ai/app/services/marine/documents/sop/text_normalizer.rb
require_file custom/wijaya/batteries/marine_ai/app/jobs/marine/documents/process_job.rb
require_file custom/wijaya/batteries/marine_ai/deploy/Dockerfile.sop-processing
require_file custom/wijaya/batteries/marine_ai/deploy/install_sop_processing_dependencies.sh
# Dedicated, resource-capped SOP worker + optional catalog secret live in a Battery
# overlay so the base production compose boots core Rails/Sidekiq with no Marine var.
require_file custom/wijaya/batteries/marine_ai/deploy/docker-compose.marine-sop.yml
require_marker custom/wijaya/batteries/marine_ai/deploy/docker-compose.marine-sop.yml "marine_sop_worker"
# The base compose must NOT carry the mandatory Marine catalog secret mount anymore.
if grep -q "MARINE_CATALOG_PG_PASSWORD_FILE" docker-compose.production.yaml 2>/dev/null; then
  echo "FORBIDDEN: base docker-compose.production.yaml still references MARINE_CATALOG_PG_PASSWORD_FILE (must live in the Battery overlay)" >&2
  missing=1
fi
# Commit 1C — registered specs
require_file spec/custom/wijaya/batteries/marine_ai/documents/command_runner_spec.rb
require_file spec/custom/wijaya/batteries/marine_ai/documents/sop/extraction_service_spec.rb
require_file spec/custom/wijaya/batteries/marine_ai/documents/sop/text_normalizer_spec.rb
require_file spec/custom/wijaya/batteries/marine_ai/documents/sop/pdf_extractor_spec.rb
require_file spec/custom/wijaya/batteries/marine_ai/documents/sop/image_ocr_service_spec.rb
require_file spec/custom/wijaya/batteries/marine_ai/documents/create_sop_service_spec.rb
require_file spec/custom/wijaya/batteries/marine_ai/documents/process_job_spec.rb
require_file spec/custom/wijaya/batteries/marine_ai/documents/sop/extraction_smoke_spec.rb
require_file spec/custom/wijaya/batteries/marine_ai/controllers/documents_sop_controller_spec.rb
# Commit 1D — SOP indexing pipeline
require_file custom/wijaya/batteries/marine_ai/app/services/marine/documents/sop/chunker.rb
require_file spec/custom/wijaya/batteries/marine_ai/documents/sop/chunker_spec.rb
require_file spec/custom/wijaya/batteries/marine_ai/documents/response_builder_job_spec.rb
require_file custom/wijaya/batteries/marine_ai/app/controllers/api/v1/accounts/marine/assistant_responses_controller.rb
require_file custom/wijaya/batteries/marine_ai/app/controllers/api/v1/accounts/marine/inboxes_controller.rb
require_file custom/wijaya/batteries/marine_ai/app/controllers/api/v1/accounts/marine/preferences_controller.rb
require_file custom/wijaya/batteries/marine_ai/app/controllers/api/v1/accounts/marine/llm_settings_controller.rb
require_file custom/wijaya/batteries/marine_ai/app/models/marine/copilot_thread.rb
require_file custom/wijaya/batteries/marine_ai/app/models/marine/copilot_message.rb
require_file custom/wijaya/batteries/marine_ai/app/services/marine/copilot/search_base_service.rb
require_file custom/wijaya/batteries/marine_ai/app/services/marine/copilot/search_conversations_service.rb
require_file custom/wijaya/batteries/marine_ai/app/services/marine/copilot/get_conversation_service.rb
require_file custom/wijaya/batteries/marine_ai/app/services/marine/copilot/search_contacts_service.rb
require_file custom/wijaya/batteries/marine_ai/app/services/marine/copilot/get_contact_service.rb
require_file custom/wijaya/batteries/marine_ai/app/services/marine/copilot/query_service.rb
require_file custom/wijaya/batteries/marine_ai/app/services/marine/agent/scenario_selector.rb
require_file custom/wijaya/batteries/marine_ai/app/services/marine/agent/runner.rb
require_file custom/wijaya/batteries/marine_ai/app/controllers/api/v1/accounts/marine/copilot_threads_controller.rb
require_file custom/wijaya/batteries/marine_ai/app/controllers/api/v1/accounts/marine/copilot_messages_controller.rb
require_file custom/wijaya/batteries/marine_ai/app/policies/marine/copilot_thread_policy.rb
require_file custom/wijaya/batteries/marine_ai/app/policies/marine/copilot_message_policy.rb
require_file db/migrate/20260708010000_create_wijaya_marine_tables.rb
require_file db/migrate/20260708010001_create_wijaya_marine_inboxes.rb
require_file db/migrate/20260709030000_create_marine_copilot_tables.rb
require_file custom/wijaya/batteries/marine_ai/frontend/api/copilotThreads.js
require_file custom/wijaya/batteries/marine_ai/frontend/api/copilotMessages.js
require_file custom/wijaya/batteries/marine_ai/frontend/routes/marine/copilot/Index.vue
require_file custom/wijaya/batteries/marine_ai/frontend/api/tasks.js
require_file custom/wijaya/batteries/marine_ai/frontend/api/assistant.js
require_file custom/wijaya/batteries/marine_ai/frontend/api/response.js
require_file custom/wijaya/batteries/marine_ai/frontend/api/document.js
require_file custom/wijaya/batteries/marine_ai/frontend/api/inboxes.js
require_file custom/wijaya/batteries/marine_ai/frontend/api/preferences.js
require_file custom/wijaya/batteries/marine_ai/frontend/api/llmSettings.js
require_file custom/wijaya/batteries/marine_ai/frontend/routes/marine/llm-settings/Index.vue
require_file custom/wijaya/batteries/marine_ai/frontend/routes/marine/Index.vue
require_file custom/wijaya/batteries/marine_ai/frontend/routes/marine/marine.routes.js
require_file custom/wijaya/batteries/marine_ai/frontend/routes/marine/pages/AssistantsIndexPage.vue
require_file custom/wijaya/batteries/marine_ai/frontend/routes/marine/composables/useMarineAssistants.js
require_file custom/wijaya/batteries/marine_ai/frontend/routes/marine/components/MarinePageShell.vue
require_file custom/wijaya/batteries/marine_ai/frontend/routes/marine/components/MarinePageLayout.vue
require_file custom/wijaya/batteries/marine_ai/frontend/routes/marine/components/MarineSettingsHeader.vue
require_file custom/wijaya/batteries/marine_ai/frontend/routes/marine/components/MarineAssistantBasicSettingsForm.vue
require_file custom/wijaya/batteries/marine_ai/frontend/routes/marine/components/MarineAssistantSystemSettingsForm.vue
require_file custom/wijaya/batteries/marine_ai/frontend/routes/marine/components/MarineAssistantControlItems.vue
require_file custom/wijaya/batteries/marine_ai/frontend/routes/marine/components/MarineDeleteDialog.vue
require_file custom/wijaya/batteries/marine_ai/frontend/routes/marine/components/MarineAssistantPlayground.vue
require_file custom/wijaya/batteries/marine_ai/frontend/routes/marine/components/MarineMessageList.vue
require_file custom/wijaya/batteries/marine_ai/frontend/routes/marine/components/MarineAssistantSwitcher.vue
require_file custom/wijaya/batteries/marine_ai/frontend/routes/marine/components/MarineDocumentCard.vue
require_file custom/wijaya/batteries/marine_ai/frontend/routes/marine/components/CreateDocumentDialog.vue
# Product Catalog UI — Wijaya-owned family picker + regression specs.
require_file custom/wijaya/batteries/marine_ai/frontend/MarineProductFamilySelect.vue
require_file custom/wijaya/batteries/marine_ai/frontend/routes/marine/components/specs/MarineProductFamilySelect.spec.js
require_file custom/wijaya/batteries/marine_ai/frontend/routes/marine/components/specs/MarineDocumentCard.spec.js
require_file custom/wijaya/batteries/marine_ai/frontend/routes/marine/components/DocumentPageEmptyState.vue
require_file custom/wijaya/batteries/marine_ai/frontend/routes/marine/components/MarineResponseCard.vue
require_file custom/wijaya/batteries/marine_ai/frontend/routes/marine/components/CreateResponseDialog.vue
require_file custom/wijaya/batteries/marine_ai/frontend/routes/marine/components/ResponsePageEmptyState.vue
require_file custom/wijaya/batteries/marine_ai/frontend/routes/marine/components/MarineInboxCard.vue
require_file custom/wijaya/batteries/marine_ai/frontend/routes/marine/components/ConnectInboxDialog.vue
require_file custom/wijaya/batteries/marine_ai/frontend/routes/marine/components/InboxPageEmptyState.vue
require_file custom/wijaya/batteries/marine_ai/frontend/routes/marine/responses/Index.vue
require_file custom/wijaya/batteries/marine_ai/frontend/routes/marine/documents/Index.vue
# Commit 1E — SOP document UI: API create workflow coverage.
require_file custom/wijaya/batteries/marine_ai/frontend/api/specs/document.spec.js
# Commit 1E — extracted testable helpers + confidentiality/UI regression coverage.
require_file custom/wijaya/batteries/marine_ai/frontend/routes/marine/helpers/documentHelpers.js
require_file custom/wijaya/batteries/marine_ai/frontend/routes/marine/helpers/specs/documentHelpers.spec.js
require_file custom/wijaya/batteries/marine_ai/frontend/routes/marine/helpers/specs/chunkCountI18n.spec.js
require_file custom/wijaya/batteries/marine_ai/frontend/routes/marine/components/specs/CreateDocumentDialog.spec.js
require_file spec/custom/wijaya/batteries/marine_ai/documents/serializer_spec.rb
require_file spec/custom/wijaya/batteries/marine_ai/documents/sync_service_spec.rb
require_file custom/wijaya/batteries/marine_ai/frontend/routes/marine/scenarios/Index.vue
require_file custom/wijaya/batteries/marine_ai/frontend/routes/marine/playground/Index.vue
require_file custom/wijaya/batteries/marine_ai/frontend/routes/marine/inboxes/Index.vue
require_file custom/wijaya/batteries/marine_ai/frontend/routes/marine/settings/Index.vue
require_file custom/wijaya/batteries/marine_ai/frontend/routes/settings-marine/Index.vue
require_file custom/wijaya/batteries/marine_ai/frontend/routes/settings-marine/marine.routes.js
require_file custom/wijaya/batteries/marine_ai/frontend/i18n/marine.json
# Native Captain composable is restored to upstream and only wrapped by the Battery
# adapter (import + one delegation at the return boundary). The adapter and Copilot
# menu filter own all Marine routing/business logic. Regression specs cover the
# non-Marine Captain translate/translate_reply fallthrough and the adapter itself.
require_file custom/wijaya/batteries/marine_ai/frontend/useMarineCaptain.js
require_file custom/wijaya/batteries/marine_ai/frontend/copilotMenu.js
require_file custom/wijaya/batteries/marine_ai/frontend/specs/useMarineCaptain.spec.js
require_file custom/wijaya/batteries/marine_ai/frontend/specs/CopilotMenuBar.spec.js
require_file app/javascript/dashboard/composables/spec/useCaptain.spec.js

for file in \
  app/services/message_templates/hook_execution_service.rb \
  app/views/api/v1/models/_inbox.json.jbuilder \
  app/javascript/dashboard/routes/dashboard/dashboard.routes.js \
  app/javascript/dashboard/routes/dashboard/settings/settings.routes.js \
  app/javascript/dashboard/composables/useCaptain.js \
  app/javascript/dashboard/components/widgets/WootWriter/CopilotMenuBar.vue \
  app/javascript/dashboard/components/widgets/WootWriter/ReplyTopPanel.vue \
  app/javascript/dashboard/components-next/sidebar/Sidebar.vue \
  app/javascript/dashboard/i18n/locale/en/index.js; do
  require_marker "$file" "WIJAYA_CUSTOM_START marine_ai"
  require_marker "$file" "WIJAYA_CUSTOM_END marine_ai"
done

# marine_ai_provisioning
require_file custom/wijaya/batteries/marine_ai/app/services/marine/provisioning/errors.rb
require_file custom/wijaya/batteries/marine_ai/app/services/marine/provisioning/config.rb
require_file custom/wijaya/batteries/marine_ai/app/services/marine/provisioning/identifier_validator.rb
require_file custom/wijaya/batteries/marine_ai/app/services/marine/provisioning/connection.rb
require_file custom/wijaya/batteries/marine_ai/app/services/marine/provisioning/state_store.rb
require_file custom/wijaya/batteries/marine_ai/app/services/marine/provisioning/audit.rb
require_file custom/wijaya/batteries/marine_ai/app/services/marine/provisioning/error_sanitizer.rb
require_file custom/wijaya/batteries/marine_ai/app/services/marine/provisioning/provision_service.rb
require_file custom/wijaya/batteries/marine_ai/app/services/marine/provisioning/privilege_service.rb
require_file custom/wijaya/batteries/marine_ai/app/services/marine/provisioning/catalog_service.rb
require_file custom/wijaya/batteries/marine_ai/app/controllers/api/v1/accounts/marine/provisioning_controller.rb
require_file custom/wijaya/batteries/marine_ai/app/policies/marine/provisioning_policy.rb
require_file custom/wijaya/batteries/marine_ai/deploy/docker-compose.marine-provisioning.yml
require_file custom/wijaya/batteries/marine_ai/deploy/marine-provisioning.env.example
require_file custom/wijaya/batteries/marine_ai/deploy/README.md
require_file custom/wijaya/batteries/marine_ai/frontend/provisioning.js
require_file custom/wijaya/batteries/marine_ai/frontend/MarineProvisioningSection.vue
require_file custom/wijaya/batteries/marine_ai/frontend/MarineProvisioningCredentialsDialog.vue
# English provisioning strings live inside the battery (local Vue i18n), NOT core marine.json.
require_file custom/wijaya/batteries/marine_ai/frontend/i18n/en.json

for file in \
  custom/wijaya/batteries/marine_ai/frontend/routes/marine/settings/Index.vue; do
  require_marker "$file" "WIJAYA_CUSTOM_START marine_ai_provisioning"
  require_marker "$file" "WIJAYA_CUSTOM_END marine_ai_provisioning"
done

# The custom loader wires the provisioning battery's app/ subtree into Zeitwerk. This
# is custom infrastructure (no WIJAYA markers needed); verify the registration text.
require_marker custom/wijaya/batteries/marine_ai/loader.rb "register_provisioning_battery_paths!"

# ---------------------------------------------------------------------------
# Boundary enforcement (diff-based)
# ---------------------------------------------------------------------------
# 1) No WHOLE Wijaya custom file may live under app/ or config/. The only allowed
#    Wijaya-authored addition there is the single generic initializer
#    config/initializers/wijaya.rb. Upstream files that merely carry WIJAYA_CUSTOM
#    marker hooks are modifications (they already exist in the baseline) and are
#    allowed. A Wijaya file is detected by a WIJAYA_CUSTOM marker or a
#    wijaya/marine/meta-routing/erp-lead filename; a *new* one is any such file that
#    is absent from the deployed baseline (origin/production).
base_ref="origin/production"
if git rev-parse --verify -q "$base_ref" >/dev/null 2>&1; then
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    [[ "$f" == "config/initializers/wijaya.rb" ]] && continue
    # Files already present in the baseline are upstream-owned (marker-hooked) — allowed.
    if git cat-file -e "$base_ref:$f" 2>/dev/null; then
      continue
    fi
    echo "FORBIDDEN: new Wijaya custom file under app/config must live in a battery: $f" >&2
    missing=1
  done < <( {
      git grep -lI --untracked "WIJAYA_CUSTOM" -- 'app' 'config' 2>/dev/null
      { git ls-files -- 'app' 'config'; git ls-files --others --exclude-standard -- 'app' 'config'; } \
        | grep -iE '(^|/)(marine|wijaya|metaadsrouting|erp_lead)' 2>/dev/null
    } | sort -u )
else
  echo "WARN: baseline ref '$base_ref' not found; skipping app/config addition enforcement" >&2
fi

# 2) All Wijaya custom code must live under custom/wijaya/batteries/**. The only
#    other allowed location is the patch registry under custom/wijaya/patches/**.
#    Root patch scripts (repo root), db/migrate schema, and Battery deploy overlays
#    (already under batteries/) are outside this scan and are not flagged.
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  case "$f" in
    custom/wijaya/batteries/*) continue ;;
    custom/wijaya/patches/*) continue ;;
  esac
  echo "FORBIDDEN: custom/wijaya path outside canonical batteries/ (patches/ excepted): $f" >&2
  missing=1
done < <( { git ls-files -- 'custom/wijaya'; git ls-files --others --exclude-standard -- 'custom/wijaya'; } | sort -u )

# 3) Registry completeness: every battery file this checker require_file's must be
#    inventoried in the patch registry, so the enforced battery surface and the
#    registry can never silently drift apart. Deterministic self-scan of the
#    require_file lines above; idempotent and free of any external state.
registry_file="custom/wijaya/patches/patch_registry.yml"
if [[ -f "$registry_file" ]]; then
  while IFS= read -r batt; do
    [[ -z "$batt" ]] && continue
    # Require an EXACT YAML sequence item (`- <path>`): allow leading indentation
    # and whitespace after the dash, but the complete item value must equal the
    # path. A substring/comment occurrence or a longer scalar with this path as a
    # prefix must NOT satisfy the invariant.
    if ! awk -v want="$batt" '
      { line = $0
        sub(/^[[:space:]]+/, "", line)      # drop indentation
        if (substr(line, 1, 1) != "-") next  # only sequence items (skips comments)
        val = substr(line, 2)                 # strip the dash
        sub(/^[[:space:]]+/, "", val)        # strip whitespace after dash
        sub(/[[:space:]]+$/, "", val)        # strip trailing whitespace
        if (val == want) { found = 1; exit }
      }
      END { exit(found ? 0 : 1) }
    ' "$registry_file"; then
      echo "MISSING registry entry for battery file required by checker: $batt (record it in $registry_file)" >&2
      missing=1
    fi
  done < <(grep -oE 'require_file[[:space:]]+custom/wijaya/batteries/[^[:space:]]+' check_custom_patches.sh | awk '{print $2}' | sort -u)
fi

if [[ "$missing" -ne 0 ]]; then
  exit 1
fi

echo "Wijaya custom patches OK"
