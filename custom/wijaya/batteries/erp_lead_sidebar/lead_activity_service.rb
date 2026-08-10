# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'
require 'securerandom'

# Orchestrates a single manual Lead Activity insert into ERPNext.
#
# Contract highlights:
#   * ERP request is exactly POST {base}/api/method/frappe.client.insert with the
#     body built by LeadActivityPayloadBuilder (parent is server-derived).
#   * Idempotency + retry safety keyed on the client submission UUID using the
#     existing Redis::Alfred NX lock pattern:
#       - a short in-flight lock (LOCK_TTL) serializes concurrent double-clicks;
#       - a bounded outcome cache (OUTCOME_TTL) records success / outcome_unknown.
#   * A cached success returns generic success with NO ERP POST.
#   * A cached outcome_unknown blocks resubmission with a sanitized warning.
#   * Timeout / connection loss / 5xx / ambiguous failure => outcome_unknown.
#   * Local validation errors and definite 4xx rejections release the lock and
#     allow an explicit corrected retry (no outcome cached). No automatic retry.
#   * person_in_charge is chosen manually by the agent and arrives as an untrusted
#     param. Blank is permitted (the ERP field is optional). Any nonblank value is
#     exact-revalidated against the live ERP User directory (LeadActivityPersonDirectory)
#     immediately before insert: an unknown/disabled/deleted/Guest/stale value yields
#     a definite 422 and zero POST; a directory outage yields a 502 and zero POST.
#     Neither pre-insert failure caches an outcome, so a corrected retry is allowed.
#
# Declared with the nested module style (matching the sibling battery files) so
# the unqualified sibling references (Config, SafeHttp, PayloadBuilder, etc.)
# resolve.
module Wijaya::Batteries::ErpLeadSidebar
  class LeadActivityService
    LOCK_TTL = 30
    OUTCOME_TTL = 24 * 60 * 60
    SUCCESS_MESSAGE = 'Lead Activity added successfully.'
    UNKNOWN_WARNING = 'ERP may have accepted it and must be checked before creating a new submission.'
    LOCK_PREFIX = 'wijaya:erp_lead_activity:lock'
    OUTCOME_PREFIX = 'wijaya:erp_lead_activity:outcome'

    # Immutable result the controller renders. `status` is the machine code,
    # `http_status` the Rails render status, `body` the JSON payload.
    Result = Struct.new(:status, :http_status, :body, keyword_init: true)

    def initialize(draft:, agent:, params:)
      @draft = draft
      @account = draft.account
      @agent = agent
      @params = (params || {}).transform_keys(&:to_s)
    end

    def perform
      return missing_lead_result if @draft.erp_lead_id.to_s.strip.empty?

      submission_id = normalized_submission_id
      return invalid_submission_result if submission_id.nil?

      case read_outcome(submission_id)
      when 'success' then return cached_success_result
      when 'outcome_unknown' then return blocked_unknown_result
      end

      with_in_flight_lock(submission_id) { perform_insert(submission_id) }
    end

    private

    # --- lock lifecycle -------------------------------------------------------

    def with_in_flight_lock(submission_id)
      token = SecureRandom.hex(16)
      acquired = Redis::Alfred.set(lock_key(submission_id), token, nx: true, ex: LOCK_TTL)
      return in_flight_result unless acquired

      begin
        yield
      ensure
        Redis::Alfred.delete_if_equals(lock_key(submission_id), token)
      end
    end

    def perform_insert(submission_id)
      valid_activities = fetch_valid_activities
      return options_unavailable_result if valid_activities.nil?

      person_in_charge = resolve_person_in_charge
      return person_in_charge if person_in_charge.is_a?(Result) # PIC rejection / directory outage

      payload = build_payload(submission_id, valid_activities, person_in_charge)
      return payload if payload.is_a?(Result) # validation failure

      post_activity(submission_id, payload)
    end

    def build_payload(submission_id, valid_activities, person_in_charge)
      LeadActivityPayloadBuilder.new(
        fields: @params,
        parent: @draft.erp_lead_id,
        submission_id: submission_id,
        valid_activities: valid_activities,
        person_in_charge: person_in_charge
      ).payload
    rescue ValidationError => e
      validation_result(e.message)
    end

    # --- ERP insert -----------------------------------------------------------

    def post_activity(submission_id, payload)
      response = SafeHttp.request(
        method: :post,
        uri: insert_uri,
        api_key: Config.erp_api_key(@account),
        api_secret: Config.erp_api_secret(@account),
        body: payload.to_json
      )

      if response.is_a?(Net::HTTPSuccess)
        write_outcome(submission_id, 'success')
        log_outcome(submission_id, 'success', response.code)
        success_result
      elsif definite_rejection?(response)
        # A definite 4xx rejection is a client-fixable error: allow a corrected
        # retry and do NOT poison the submission id with an outcome cache.
        log_outcome(submission_id, 'rejected', response.code)
        rejection_result
      else
        # 5xx / other ambiguous status: ERP may or may not have persisted it.
        write_outcome(submission_id, 'outcome_unknown')
        log_outcome(submission_id, 'outcome_unknown', response.code)
        fresh_unknown_result
      end
    rescue SafeHttp::TimeoutError, SafeHttp::Error
      # Transport failure after the request left us: treat as ambiguous.
      write_outcome(submission_id, 'outcome_unknown')
      log_outcome(submission_id, 'outcome_unknown', 'transport_error')
      fresh_unknown_result
    end

    def definite_rejection?(response)
      code = response.code.to_i
      code >= 400 && code < 500
    end

    def insert_uri
      URI.parse("#{Config.erp_base_url(@account).chomp('/')}/api/method/frappe.client.insert")
    end

    # --- options fetch --------------------------------------------------------

    # Returns the master name list, or nil when unavailable (reject before insert).
    def fetch_valid_activities
      LeadActivityOptionsService.new(@account).fetch_names
    rescue SyncError
      nil
    end

    # --- person in charge -----------------------------------------------------

    # The manually chosen person in charge, taken only from the untrusted params.
    # Blank is permitted and continues (the ERP field is optional). A nonblank
    # value is exact-revalidated against the live ERP User directory: an invalid
    # value returns a definite 422 Result (no POST), a directory outage returns a
    # 502 Result (no POST). Neither caches an outcome, so a corrected retry works.
    # Returns the validated name string, '' for blank, or a Result to short-circuit.
    def resolve_person_in_charge
      candidate = @params['person_in_charge'].to_s.strip
      return '' if candidate.empty?
      return candidate if LeadActivityPersonDirectory.valid?(@account, candidate)

      person_invalid_result
    rescue SyncError
      person_unavailable_result
    end

    # --- redis helpers --------------------------------------------------------

    def lock_key(submission_id)
      "#{LOCK_PREFIX}:#{@account.id}:#{submission_id}"
    end

    def outcome_key(submission_id)
      "#{OUTCOME_PREFIX}:#{@account.id}:#{submission_id}"
    end

    def read_outcome(submission_id)
      Redis::Alfred.get(outcome_key(submission_id))
    end

    # Best-effort 24h outcome record (documented TTL).
    def write_outcome(submission_id, value)
      Redis::Alfred.set(outcome_key(submission_id), value, ex: OUTCOME_TTL)
    end

    # --- validation helpers ---------------------------------------------------

    def normalized_submission_id
      value = @params['submission_id'].to_s.strip
      value.match?(LeadActivityPayloadBuilder::UUID_REGEX) ? value : nil
    end

    # --- structured, sanitized logging ---------------------------------------

    def log_outcome(submission_id, status, code)
      Rails.logger.info(
        '[Wijaya] erp_lead_activity ' \
        "account=#{@account.id} conversation=#{@draft.conversation_id} lead=#{@draft.erp_lead_id} " \
        "user=#{@agent&.id} submission=#{submission_id} type=insert status=#{status} erp_code=#{code}"
      )
    rescue StandardError
      nil
    end

    # --- result builders ------------------------------------------------------

    def success_result
      Result.new(status: 'success', http_status: :ok, body: { status: 'success', message: SUCCESS_MESSAGE })
    end

    def cached_success_result
      Result.new(status: 'success', http_status: :ok, body: { status: 'success', message: SUCCESS_MESSAGE })
    end

    def in_flight_result
      Result.new(
        status: 'in_flight', http_status: :conflict,
        body: { status: 'in_flight', error: 'A Lead Activity submission is already in progress.' }
      )
    end

    def blocked_unknown_result
      Result.new(status: 'outcome_unknown', http_status: :conflict, body: { status: 'outcome_unknown', warning: UNKNOWN_WARNING })
    end

    def fresh_unknown_result
      Result.new(status: 'outcome_unknown', http_status: :bad_gateway, body: { status: 'outcome_unknown', warning: UNKNOWN_WARNING })
    end

    def missing_lead_result
      Result.new(
        status: 'no_lead', http_status: :unprocessable_entity,
        body: { status: 'no_lead', error: 'Create or link an ERP Lead before adding an activity.' }
      )
    end

    def invalid_submission_result
      Result.new(
        status: 'invalid', http_status: :unprocessable_entity,
        body: { status: 'invalid', error: 'Invalid submission identifier.' }
      )
    end

    def validation_result(message)
      Result.new(status: 'invalid', http_status: :unprocessable_entity, body: { status: 'invalid', error: message })
    end

    def options_unavailable_result
      Result.new(
        status: 'options_unavailable', http_status: :bad_gateway,
        body: { status: 'options_unavailable', error: 'Lead Activity options are currently unavailable. Please try again.' }
      )
    end

    def rejection_result
      Result.new(
        status: 'rejected', http_status: :unprocessable_entity,
        body: { status: 'rejected', error: 'ERPNext rejected the Lead Activity. Please review the fields and retry.' }
      )
    end

    # A nonblank Person In Charge that is not an exact, currently-selectable ERP
    # User: a definite client-fixable rejection (no POST, no cached outcome).
    def person_invalid_result
      Result.new(
        status: 'invalid', http_status: :unprocessable_entity,
        body: { status: 'invalid', error: 'Person In Charge is not a valid ERP user. Please pick one from the list.' }
      )
    end

    # The ERP User directory could not be reached to revalidate a nonblank
    # Person In Charge: ambiguous availability, so refuse the insert (no POST, no
    # cached outcome) and let the agent retry.
    def person_unavailable_result
      Result.new(
        status: 'options_unavailable', http_status: :bad_gateway,
        body: { status: 'options_unavailable', error: 'Person In Charge could not be verified right now. Please try again.' }
      )
    end
  end
end
