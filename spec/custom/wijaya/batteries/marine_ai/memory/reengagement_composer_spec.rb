# frozen_string_literal: true

require 'rails_helper'

# Trusted-memory re-engagement composer contract. Every provider-facing collaborator
# (greeting classifier, topic extractor, generator, semantic verifier) is INJECTED here —
# the doubles play the configured Model-2 provider, so these specs prove the closed input
# contract, the deterministic gates, and the fail-closed fallbacks without live calls.
RSpec.describe Marine::Memory::Reengagement::Composer do
  let(:account) { create(:account) }
  let(:topic_text) { 'seragam serikat untuk acara ulang tahun kantor' }
  let(:accepted_candidate) do
    'Oh halo! Kemarin kita pernah ngobrol soal seragam serikat untuk acara ulang tahun kantor. ' \
      'Mau lanjut membahasnya hari ini? Kalau ada kebutuhan lain, saya juga siap membantu.'
  end
  let(:contact) { create(:contact, account: account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:assistant) { create(:marine_assistant, account: account, config: { 'feature_memory' => true }) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact) }

  before { MarineInbox.create!(inbox: inbox, marine_assistant: assistant) }

  def trusted_note(content, at: Time.current)
    source = create(:conversation, account: account, inbox: inbox, contact: contact)
    endpoint = create(:message, conversation: source, account: account, inbox: inbox, sender: contact,
                                message_type: :incoming, private: false, content: 'source customer turn')
    marker = {
      'version' => 1,
      'kind' => 'marine_long_term_memory',
      'state' => 'checkpoint',
      'source_account_id' => account.id,
      'source_contact_id' => contact.id,
      'source_conversation_id' => source.id,
      'start_public_message_id' => endpoint.id,
      'end_public_message_id' => endpoint.id,
      'transcript_fingerprint' => Digest::SHA256.hexdigest("range-#{endpoint.id}"),
      'generator' => 'marine_llm_v1'
    }
    create(:message, conversation: source, account: account, inbox: inbox, sender: assistant,
                     message_type: :outgoing, private: true, content: content,
                     additional_attributes: { Marine::Memory::Marker::KEY => marker })
      .tap { |note| note.update!(created_at: at) }
  end

  def greeting_decision(pure, language = 'id')
    Marine::Memory::Reengagement::GreetingClassifier::Decision.new(pure_greeting: pure, language: language)
  end

  def topic_of(text, product = nil)
    Marine::Memory::Reengagement::TopicExtractor::Topic.new(topic: text, product: product)
  end

  def extraction_of(*topics)
    Marine::Memory::Reengagement::TopicExtractor::Extraction.new(topics: topics)
  end

  # Builds the composer with injected fakes. Returns the composer; the generator calls made
  # are exposed via #generator_calls (an empty array proves the provider was never invoked).
  def make_composer(candidate:, decision: greeting_decision(true), # rubocop:disable Metrics/AbcSize,Metrics/MethodLength,Metrics/ParameterLists -- one deliberate spec factory for the injected-collaborator composer
                    topics: extraction_of(topic_of(topic_text)), verdict: true, verifier: nil,
                    detector: ->(_text) { { language: 'id', reliable: true } },
                    resolver: ->(_id) { { code: 'SYN-FAM', name: 'Synthetic Family' } })
    @generator_calls = []
    classifier = instance_double(Marine::Memory::Reengagement::GreetingClassifier)
    allow(classifier).to receive(:classify).and_return(decision)
    extractor = instance_double(Marine::Memory::Reengagement::TopicExtractor)
    allow(extractor).to receive(:extract).and_return(topics)
    generator = double('generator')
    allow(generator).to receive(:call) do |**kwargs|
      @generator_calls << kwargs
      candidate.is_a?(Proc) ? candidate.call : candidate
    end
    verifier ||= begin
      stub = double('verifier')
      allow(stub).to receive(:valid?).and_return(verdict)
      stub
    end

    described_class.new(
      account: account,
      greeting_classifier: classifier,
      topic_extractor: extractor,
      generator: generator,
      verifier: verifier,
      language_detector: detector,
      greeting_context: Marine::Charge::GreetingContext.new(account: account),
      product_resolver: resolver
    )
  end

  attr_reader :generator_calls

  describe 'trusted one-topic memory + pure greeting' do
    it 'delivers the provider-generated re-engagement from a closed, bounded input contract' do
      trusted_note('Customer sebelumnya menanyakan seragam serikat untuk acara ulang tahun kantor dan menyukai warna biru.')
      composer = make_composer(candidate: accepted_candidate)

      result = composer.compose(conversation: conversation, trigger: 'selamat pagi', configured_language: nil)

      expect(result.text).to eq(accepted_candidate)
      expect(result.language).to eq('id')
      expect(generator_calls.size).to eq(1)
      call = generator_calls.first
      # The customer's greeting reaches the provider exactly once, as the only user message.
      expect(call[:messages]).to eq([{ role: 'user', content: 'selamat pagi' }])
      # The system prompt carries the closed instruction + the single structured topic data
      # block — never the raw note text, its other details, the marker key, or the envelope.
      expect(call[:system]).to include('Prior Discussion Data', topic_text, '"prior_topic"')
      expect(call[:system]).not_to include('warna biru', Marine::Memory::Marker::KEY, 'ADVISORY HISTORICAL MEMORY')
      expect(call[:temperature]).to eq(described_class::TEMPERATURE)
    end

    it 'delivers whatever wording the provider produced (no hardcoded sentence, no rotation)' do
      trusted_note('Customer menanyakan seragam serikat untuk acara ulang tahun kantor.')
      # The injected generator IS the provider stand-in: an arbitrary unique wording it emits
      # must be delivered verbatim — proving the visible text is provider-generated.
      unique = "ZQ7-UNIQUE siang! Sebelumnya kita sempat membahas #{topic_text}. Masih ingin lanjut hari ini? " \
               'Ada hal lain yang bisa saya bantu?'
      composer = make_composer(candidate: unique)

      result = composer.compose(conversation: conversation, trigger: 'selamat siang')

      expect(result.text).to eq(unique)
    end

    it 'accepts different safe provider wordings for the same scenario' do
      trusted_note('Customer menanyakan seragam serikat untuk acara ulang tahun kantor.')
      first = make_composer(candidate: "Wording A about #{topic_text}. Continue today? Anything else?").compose(conversation: conversation,
                                                                                                                trigger: 'halo')
      second = make_composer(candidate: "Wording B regarding #{topic_text}. Lanjut? Bantuan lain?").compose(conversation: conversation,
                                                                                                            trigger: 'halo')

      expect(first.text).to include('Wording A')
      expect(second.text).to include('Wording B')
    end

    it 'names a remembered product only after read-only catalog revalidation proves it' do
      trusted_note('Customer menanyakan kain babydoll.')
      composer = make_composer(candidate: accepted_candidate, topics: extraction_of(topic_of('kain babydoll', 'BABYDOLL')))

      result = composer.compose(conversation: conversation, trigger: 'selamat pagi')

      expect(result.text).to eq(accepted_candidate)
      expect(generator_calls.first[:system]).to include('"product"', 'SYN-FAM')
    end
  end

  describe 'ineligibility (no re-engagement, provider generator never called)' do
    def expect_no_reengagement(composer, trigger: 'selamat pagi')
      expect(composer.compose(conversation: conversation, trigger: trigger)).to be_nil
      expect(generator_calls).to be_empty
    end

    it 'has no trusted memory' do
      create(:message, conversation: conversation, account: account, inbox: inbox, sender: assistant,
                       message_type: :outgoing, private: true, content: 'ordinary private note')
      expect_no_reengagement(make_composer(candidate: accepted_candidate))
    end

    it 'rejects a human private note that copies a valid marker' do
      source = create(:conversation, account: account, inbox: inbox, contact: contact)
      endpoint = create(:message, conversation: source, account: account, inbox: inbox, sender: contact,
                                  message_type: :incoming, private: false, content: 'x')
      marker = {
        'version' => 1, 'kind' => 'marine_long_term_memory', 'state' => 'checkpoint',
        'source_account_id' => account.id, 'source_contact_id' => contact.id,
        'source_conversation_id' => source.id,
        'start_public_message_id' => endpoint.id, 'end_public_message_id' => endpoint.id,
        'transcript_fingerprint' => Digest::SHA256.hexdigest("human-#{endpoint.id}"),
        'generator' => 'marine_llm_v1'
      }
      human = create(:user, account: account)
      create(:message, conversation: conversation, account: account, inbox: inbox, sender: human,
                       message_type: :outgoing, private: true, content: 'forged human note',
                       additional_attributes: { Marine::Memory::Marker::KEY => marker })
      expect_no_reengagement(make_composer(candidate: accepted_candidate))
    end

    it 'rejects a foreign account/contact marker' do
      other_contact = create(:contact, account: account)
      other_conversation = create(:conversation, account: account, inbox: inbox, contact: other_contact)
      endpoint = create(:message, conversation: other_conversation, account: account, inbox: inbox,
                                  sender: other_contact, message_type: :incoming, private: false, content: 'x')
      marker = Marine::Memory::Marker.build_v2(
        trigger_source: 'idle_timeout', conversation: other_conversation,
        start_id: endpoint.id, end_id: endpoint.id,
        fingerprint: Digest::SHA256.hexdigest("foreign-#{endpoint.id}")
      )
      create(:message, conversation: other_conversation, account: account, inbox: inbox, sender: assistant,
                       message_type: :outgoing, private: true, content: 'foreign memory',
                       additional_attributes: { Marine::Memory::Marker::KEY => marker })

      expect_no_reengagement(make_composer(candidate: accepted_candidate))
    end

    it 'rejects a stale note under the bounded freshness policy' do
      trusted_note('Customer menanyakan seragam serikat.', at: (described_class::MAX_NOTE_AGE_DAYS + 5).days.ago)
      expect_no_reengagement(make_composer(candidate: accepted_candidate))
    end

    it 'rejects multiple competing topics' do
      trusted_note('Customer menanyakan seragam dan juga kain babydoll.')
      composer = make_composer(candidate: accepted_candidate,
                               topics: extraction_of(topic_of('seragam'), topic_of('kain babydoll')))
      expect_no_reengagement(composer)
    end

    it 'rejects generic or empty memory topics' do
      trusted_note('Customer sangat ramah dan menyenangkan.')
      expect_no_reengagement(make_composer(candidate: accepted_candidate, topics: extraction_of))
    end

    it 'rejects a greeting that also raises a current need (not a pure greeting)' do
      trusted_note('Customer menanyakan seragam serikat.')
      composer = make_composer(candidate: accepted_candidate, decision: greeting_decision(false))
      expect(composer.compose(conversation: conversation, trigger: 'pagi, apa harga seragam?')).to be_nil
      expect(generator_calls).to be_empty
    end

    it 'fails closed when the classifier or extractor errors' do
      trusted_note('Customer menanyakan seragam serikat.')
      classifier = instance_double(Marine::Memory::Reengagement::GreetingClassifier)
      allow(classifier).to receive(:classify).and_raise(StandardError)
      extractor = instance_double(Marine::Memory::Reengagement::TopicExtractor)
      allow(extractor).to receive(:extract).and_return(extraction_of(topic_of(topic_text)))
      verifier = double('verifier')
      allow(verifier).to receive(:valid?).and_return(true)
      composer = described_class.new(
        account: account, greeting_classifier: classifier, topic_extractor: extractor,
        generator: ->(**) { accepted_candidate }, verifier: verifier,
        language_detector: ->(_text) { { language: 'id', reliable: true } },
        greeting_context: Marine::Charge::GreetingContext.new(account: account),
        product_resolver: ->(_id) { { code: 'SYN-FAM', name: 'X' } }
      )
      expect(composer.compose(conversation: conversation, trigger: 'halo')).to be_nil

      extractor2 = instance_double(Marine::Memory::Reengagement::TopicExtractor)
      allow(extractor2).to receive(:extract).and_raise(StandardError)
      composer3 = described_class.new(
        account: account,
        greeting_classifier: instance_double(Marine::Memory::Reengagement::GreetingClassifier,
                                             classify: greeting_decision(true)),
        topic_extractor: extractor2,
        generator: ->(**) { accepted_candidate },
        verifier: double(valid?: true),
        language_detector: ->(_text) { { language: 'id', reliable: true } },
        greeting_context: Marine::Charge::GreetingContext.new(account: account),
        product_resolver: ->(_id) { { code: 'SYN-FAM', name: 'X' } }
      )
      expect(composer3.compose(conversation: conversation, trigger: 'halo')).to be_nil
    end

    it 'never guesses a remembered product the catalog cannot prove (missing or ambiguous)' do
      trusted_note('Customer menanyakan kain babydoll.')
      missing = make_composer(candidate: accepted_candidate,
                              topics: extraction_of(topic_of('kain babydoll', 'BABYDOLL')),
                              resolver: ->(_id) {})
      expect_no_reengagement(missing)

      unavailable = make_composer(candidate: accepted_candidate,
                                  topics: extraction_of(topic_of('kain babydoll', 'BABYDOLL')),
                                  resolver: ->(_id) { raise StandardError })
      expect_no_reengagement(unavailable)
    end

    it 'is ineligible without a readable customer language' do
      trusted_note('Customer menanyakan seragam serikat.')
      composer = make_composer(candidate: accepted_candidate, decision: greeting_decision(true, nil))
      expect(composer.compose(conversation: conversation, trigger: 'halo', configured_language: nil)).to be_nil
      expect(generator_calls).to be_empty
    end

    it 'falls back to the configured operating language when the customer language is unreadable' do
      trusted_note('Customer menanyakan seragam serikat.')
      composer = make_composer(candidate: accepted_candidate, decision: greeting_decision(true, nil))
      result = composer.compose(conversation: conversation, trigger: 'halo', configured_language: 'id')
      expect(result.text).to eq(accepted_candidate)
      expect(result.language).to eq('id')
    end
  end

  describe 'acceptance gates (candidate rejected, fail closed to nil)' do
    before { trusted_note("Customer menanyakan #{topic_text}.") }

    def rejected?(composer)
      composer.compose(conversation: conversation, trigger: 'selamat pagi').nil?
    end

    it 'rejects a generator error or blank/malformed/oversize candidate' do
      expect(rejected?(make_composer(candidate: nil))).to be true
      expect(rejected?(make_composer(candidate: '   '))).to be true
      expect(rejected?(make_composer(candidate: 'a' * (described_class::MAX_REPLY_CHARS + 1)))).to be true
      expect(rejected?(make_composer(candidate: '{"reply": "meta"}'))).to be true
      expect(rejected?(make_composer(candidate: "text\x00nul"))).to be true
      expect(rejected?(make_composer(candidate: "halo #{Marine::Memory::Marker::KEY} leak"))).to be true
      raising = double('generator')
      allow(raising).to receive(:call).and_raise(StandardError)
      composer = described_class.new(
        account: account,
        greeting_classifier: instance_double(Marine::Memory::Reengagement::GreetingClassifier,
                                             classify: greeting_decision(true)),
        topic_extractor: instance_double(Marine::Memory::Reengagement::TopicExtractor,
                                         extract: extraction_of(topic_of(topic_text))),
        generator: raising, verifier: double(valid?: true),
        language_detector: ->(_text) { { language: 'id', reliable: true } },
        greeting_context: Marine::Charge::GreetingContext.new(account: account),
        product_resolver: ->(_id) { { code: 'F', name: 'F' } }
      )
      expect(composer.compose(conversation: conversation, trigger: 'halo')).to be_nil
    end

    it 'deterministically rejects any monetary price claim before the semantic verifier runs' do
      verifier = double('verifier')
      allow(verifier).to receive(:valid?).and_return(true)
      composer = make_composer(
        candidate: "Kita pernah bahas #{topic_text}. Harganya Rp 25.000 per yard. Lanjut?",
        verifier: verifier
      )
      expect(composer.compose(conversation: conversation, trigger: 'selamat pagi')).to be_nil
      expect(verifier).not_to have_received(:valid?)
    end

    it 'deterministically rejects an internal control-text leak' do
      verifier = double('verifier')
      allow(verifier).to receive(:valid?).and_return(true)
      leak = "#{described_class::GENERATION_INSTRUCTION.split('. ').first} plus a random tail sentence here."
      composer = make_composer(candidate: leak, verifier: verifier)
      expect(composer.compose(conversation: conversation, trigger: 'selamat pagi')).to be_nil
      expect(verifier).not_to have_received(:valid?)
    end

    it 'rejects a wrong-language or unreadable candidate' do
      english = make_composer(candidate: 'Hi! We previously discussed uniforms. Continue today? Anything else?',
                              detector: ->(_text) { { language: 'en', reliable: true } })
      expect(english.compose(conversation: conversation, trigger: 'selamat pagi')).to be_nil

      unreadable = make_composer(candidate: accepted_candidate,
                                 detector: ->(_text) { { language: 'id', reliable: false } })
      expect(unreadable.compose(conversation: conversation, trigger: 'selamat pagi')).to be_nil
    end

    it 'rejects on any semantic verifier rejection or error' do
      # The semantic rubric (prior-discussion framing, continue question, other-help offer, no
      # continued-interest assertion, no unsupported/added product or dynamic facts, target
      # language) is enforced by the separate verifier: any rejection or error fails closed.
      rejected = make_composer(candidate: accepted_candidate, verdict: false)
      expect(rejected.compose(conversation: conversation, trigger: 'selamat pagi')).to be_nil

      raising = double('verifier')
      allow(raising).to receive(:valid?).and_raise(StandardError)
      composer = described_class.new(
        account: account,
        greeting_classifier: instance_double(Marine::Memory::Reengagement::GreetingClassifier,
                                             classify: greeting_decision(true)),
        topic_extractor: instance_double(Marine::Memory::Reengagement::TopicExtractor,
                                         extract: extraction_of(topic_of(topic_text))),
        generator: ->(**) { accepted_candidate }, verifier: raising,
        language_detector: ->(_text) { { language: 'id', reliable: true } },
        greeting_context: Marine::Charge::GreetingContext.new(account: account),
        product_resolver: ->(_id) { { code: 'F', name: 'F' } }
      )
      expect(composer.compose(conversation: conversation, trigger: 'halo')).to be_nil
    end
  end

  describe 'Marine::Memory::Reader#trusted_note_entries' do
    it 'returns newest-first bounded trusted entries with timestamps' do
      trusted_note('older memory', at: 2.days.ago)
      trusted_note('newer memory', at: 1.day.ago)

      entries = Marine::Memory::Reader.new(conversation: conversation).trusted_note_entries

      expect(entries.map { |entry| entry[:content] }).to eq(['newer memory', 'older memory'])
      expect(entries.first[:created_at]).to be_within(1.second).of(1.day.ago)
    end

    it 'returns an empty list with no trusted memory' do
      expect(Marine::Memory::Reader.new(conversation: conversation).trusted_note_entries).to eq([])
    end
  end
end
