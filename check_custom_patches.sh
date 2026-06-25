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

if [[ "$missing" -ne 0 ]]; then
  exit 1
fi

echo "Wijaya custom patches OK"
