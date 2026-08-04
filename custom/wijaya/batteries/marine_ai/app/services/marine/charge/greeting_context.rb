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

  def initialize(account: nil)
    @account = account
  end

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

  private

  attr_reader :account

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
