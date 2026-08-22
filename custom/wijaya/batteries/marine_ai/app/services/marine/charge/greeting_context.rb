class Marine::Charge::GreetingContext
  # Marine serves Indonesian business hours; fall back to WIB when the account has
  # no valid reporting timezone. Rails runs in UTC, so all time-of-day logic goes
  # through ActiveSupport::TimeZone conversion rather than raw Time.now.
  DEFAULT_TIMEZONE = 'Asia/Jakarta'.freeze

  # Deterministic Indonesian time-of-day greetings keyed by local hour bucket:
  # 04:00-10:59 pagi, 11:00-14:59 siang, 15:00-17:59 sore, 18:00-03:59 malam.
  GREETINGS = { pagi: 'Selamat pagi', siang: 'Selamat siang', sore: 'Selamat sore', malam: 'Selamat malam' }.freeze
  GREETING_WORDS = GREETINGS.keys.map(&:to_s).join('|').freeze

  # Explicit salutation lead-ins allowed before a time-of-day greeting.
  OPENING_SALUTATIONS = %w[halo hai hello hi].join('|').freeze

  # Matches a time-based greeting only at the very start of a reply: either
  # "Selamat <period>" on its own, or a common salutation lead-in (Halo/Hai/Hello/Hi
  # with trailing punctuation/whitespace) immediately followed by "Selamat <period>".
  # Anchored at \A and restricted to those salutations so unrelated prose that merely
  # opens with "Selamat" — e.g. "Kami mengucapkan Selamat sore" — is never rewritten.
  OPENING_GREETING_REGEX = /\A(\s*(?:(?:#{OPENING_SALUTATIONS})[\s!,.]+)?)(selamat)\s+(#{GREETING_WORDS})\b/i

  # Matches a STANDALONE opening salutation from the same canonical set (Halo/Hai/Hello/Hi) that
  # is NOT part of a "Selamat <period>" opening greeting. Anchored at \A with optional leading
  # whitespace (the LLM reply is enforced verbatim, so it may open with stray whitespace), a
  # trailing word boundary, and a required safe separator (whitespace/punctuation) or
  # end-of-string, so it never matches a prefix word (e.g. "History"/"Halodoc") and never touches
  # a later/in-body mention. The leading whitespace and separator are part of the match so only
  # the salutation plus its surrounding whitespace/separator is removed.
  STANDALONE_OPENING_SALUTATION_REGEX = /\A\s*(?:#{OPENING_SALUTATIONS})\b(?:[\s!,.]+|\z)/i

  # Follow-up interaction policy (Phase 4): once Marine has already replied publicly in a
  # conversation, later turns are follow-ups and must not open with a fresh greeting. Generic
  # and language-neutral — it enumerates no greeting phrases; the deterministic safety net
  # (#remove_opening_greeting) reuses the same canonical opening-greeting recognition.
  #
  # It also carries a topic-reset guard: the generated-RAG history includes the prior turns, so
  # on a bare greeting/pleasantry after an earlier product exchange a plain "continue naturally"
  # cue led the model to resume that earlier request (e.g. re-answering an earlier stock question
  # in reply to "Hallo"). The guard instructs the model to answer the customer's LATEST message on
  # its own terms and not resurrect an earlier request/topic the latest message does not itself
  # raise — while still continuing genuine follow-ups. Fully generic: it names no product, phrase,
  # or language, and it never resets validated context (a later genuine follow-up may still resume
  # it); it only steers the reply toward what the customer actually said.
  FOLLOW_UP_PROMPT = <<~PROMPT.strip
    This is a follow-up message in an ongoing conversation.
    Do NOT begin your reply with an opening greeting or salutation; you have already responded earlier in this conversation, so this is an ongoing follow-up.
    Always respond to the customer's latest message on its own terms. If that latest message does not itself raise or continue a specific request or topic (for example a greeting, pleasantry, acknowledgement, or unrelated remark), do NOT reintroduce, resume, or re-answer an earlier request or topic on the customer's behalf; simply respond to what they actually said and offer further help.
    Continue the conversation naturally.
  PROMPT

  def initialize(account: nil)
    @account = account
  end

  # Follow-up interaction policy block (Phase 4), served in place of the opening business-time
  # greeting grounding once Marine has already responded earlier in the conversation (an
  # ongoing follow-up — the earlier response need not itself have carried a greeting).
  def follow_up_prompt = FOLLOW_UP_PROMPT

  # Phase-4 greeting policy for the generated-RAG system prompt: an opening turn grounds the
  # authoritative business-time greeting; a follow-up turn carries the no-new-greeting policy.
  def interaction_prompt(opening:) = opening ? system_prompt : follow_up_prompt

  # Phase-4 deterministic enforcement over the LLM reply: an opening turn corrects a wrong-time
  # opening greeting; a follow-up turn removes a recognized opening greeting entirely.
  def enforce(message, opening:) = opening ? normalize_opening_greeting(message) : remove_opening_greeting(message)

  # Authoritative current-time block for the system prompt. States the local business
  # date/time, timezone, and the correct greeting so the LLM never infers "now" from
  # stale conversation history (which produced wrong greetings, e.g. a leftover
  # "Selamat sore").
  def system_prompt
    now = business_time
    <<~PROMPT.strip
      Current business date and time: #{now.strftime('%A, %d %B %Y, %H:%M')} (#{business_timezone.name}).
      The correct Indonesian time-of-day greeting right now is "#{indonesian_greeting(now)}".
      Treat this as the authoritative current time. Do NOT infer the current time or greeting from historical conversation content or earlier messages.
    PROMPT
  end

  # Safety net over the LLM output: if the reply opens with a time-based greeting that
  # disagrees with the authoritative local time, swap only that opening greeting to the
  # correct one. Openings with no time greeting, and later in-body mentions, are left
  # untouched.
  def normalize_opening_greeting(text)
    return text if text.blank?

    expected_period = indonesian_greeting.split.last
    text.sub(OPENING_GREETING_REGEX) do
      lead = Regexp.last_match(1)
      selamat = Regexp.last_match(2)
      period = Regexp.last_match(3)
      period.casecmp?(expected_period) ? Regexp.last_match(0) : "#{lead}#{selamat} #{match_case(period, expected_period)}"
    end
  end

  # Follow-up enforcement (Phase 4): a follow-up turn must not open with a fresh greeting or
  # salutation. Remove a recognized OPENING greeting — the SAME anchored recognition used by
  # #normalize_opening_greeting (an optional Halo/Hai/Hello/Hi lead-in followed by
  # "Selamat <period>", at the very start) — OR a STANDALONE opening salutation from that same
  # canonical set (Halo/Hai/Hello/Hi not followed by "Selamat <period>"), together with its
  # trailing separator, then re-capitalize the remainder. Only a real opening greeting/salutation
  # is removed: later in-body greeting mentions, prose that merely starts with "Selamat", and
  # prefix words (e.g. "History") are never matched by the anchored recognizers and are left
  # untouched. Returns blank when the reply is only that greeting/salutation so the caller fails
  # closed. A no-op when the reply does not open with a greeting or salutation.
  def remove_opening_greeting(text)
    return text if text.blank?

    if text.match?(OPENING_GREETING_REGEX)
      remainder = text.sub(OPENING_GREETING_REGEX, '').sub(/\A[\s!,.]+/, '')
    elsif text.match?(STANDALONE_OPENING_SALUTATION_REGEX)
      remainder = text.sub(STANDALONE_OPENING_SALUTATION_REGEX, '')
    else
      return text
    end

    capitalize_first(remainder)
  end

  private

  attr_reader :account

  # Uppercase only the first character so the sentence left after removing an opening greeting
  # reads naturally; the rest of the reply is preserved verbatim.
  def capitalize_first(text)
    return text if text.empty?

    text[0].upcase + text[1..]
  end

  def business_time
    Time.now.in_time_zone(business_timezone)
  end

  # Prefer the account's configured reporting timezone; fall back to WIB when it is
  # blank or invalid. ActiveSupport::TimeZone[...] returns nil for both cases.
  def business_timezone
    configured = account.try(:reporting_timezone)
    (configured.present? && ActiveSupport::TimeZone[configured.to_s]) || ActiveSupport::TimeZone[DEFAULT_TIMEZONE]
  end

  def indonesian_greeting(time = business_time)
    key = case time.hour
          when 4..10 then :pagi
          when 11..14 then :siang
          when 15..17 then :sore
          else :malam
          end
    GREETINGS[key]
  end

  # Mirror the casing of the greeting word we are replacing so normal ("sore"),
  # title ("Sore") and uppercase ("SORE") openings stay stylistically intact.
  def match_case(source, target)
    if source == source.upcase
      target.upcase
    elsif source == source.capitalize
      target.capitalize
    else
      target.downcase
    end
  end
end
