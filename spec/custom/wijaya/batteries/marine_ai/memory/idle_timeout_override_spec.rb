# frozen_string_literal: true

require 'rails_helper'

# Operator-only Development override: memory_idle_timeout_test_minutes (5..60) shortens the
# idle window while memory_idle_timeout_hours (1..24, default 2) stays the product contract.
# Both the delayed enqueue and the idle eligibility MUST share one canonical duration.
RSpec.describe 'Marine memory idle timeout override' do
  include ActiveJob::TestHelper

  let(:account) { create(:account) }
  let(:contact) { create(:contact, account: account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:base_config) { { 'feature_memory' => true } }
  let(:assistant) { create(:marine_assistant, account: account, config: base_config) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact, status: :open) }

  before { MarineInbox.create!(inbox: inbox, marine_assistant: assistant) }

  describe 'canonical duration accessor' do
    it 'defaults to two hours when no override and no hours config are present' do
      expect(assistant.memory_idle_duration).to eq(2.hours)
    end

    it 'respects configured memory_idle_timeout_hours when the override is absent' do
      assistant.config['memory_idle_timeout_hours'] = '3'
      expect(assistant.memory_idle_duration).to eq(3.hours)
    end

    it 'uses a valid override of 5 minutes' do
      assistant.config['memory_idle_timeout_test_minutes'] = 5
      expect(assistant.memory_idle_duration).to eq(5.minutes)
    end

    it 'uses a valid override of 60 minutes' do
      assistant.config['memory_idle_timeout_test_minutes'] = 60
      expect(assistant.memory_idle_duration).to eq(60.minutes)
    end

    it 'falls back to configured hours for invalid overrides' do
      assistant.config['memory_idle_timeout_hours'] = '3'

      [4, 61, 5.5, 5.0, true, false, nil, ''].each do |invalid|
        assistant.config['memory_idle_timeout_test_minutes'] = invalid
        expect(assistant.memory_idle_duration).to eq(3.hours), "expected hours fallback for #{invalid.inspect}"
      end
    end

    it 'falls back for ANY string representation, including numeric strings' do
      assistant.config['memory_idle_timeout_hours'] = '3'

      ['5', ' 5 ', '+5', '05', '0x3c', '60', '4', '61', 'abc'].each do |invalid|
        assistant.config['memory_idle_timeout_test_minutes'] = invalid
        expect(assistant.memory_idle_duration).to eq(3.hours), "expected hours fallback for #{invalid.inspect}"
      end
    end

    it 'falls back to the default two hours for invalid overrides without hours config' do
      assistant.config['memory_idle_timeout_test_minutes'] = '4'
      expect(assistant.memory_idle_duration).to eq(2.hours)
    end

    it 'keeps working after a persisted save and reload (json round-trip keeps the Integer)' do
      [5, 60].each do |minutes|
        assistant.update!(config: base_config.merge('memory_idle_timeout_test_minutes' => minutes))
        expect(Marine::Assistant.find(assistant.id).memory_idle_duration).to eq(minutes.minutes)
      end
    end

    it 'falls back after persistence for a string value stored in config' do
      assistant.update!(config: base_config.merge('memory_idle_timeout_test_minutes' => '5'))
      expect(Marine::Assistant.find(assistant.id).memory_idle_duration).to eq(2.hours)
    end
  end

  describe 'idle eligibility in ContactNotesService' do
    def latest_public_message(at)
      create(:message, conversation: conversation, account: account, inbox: inbox, sender: contact,
                       message_type: :incoming, private: false, content: 'turn', created_at: at)
    end

    it 'treats a 10-minute-old latest public message as idle under a 5-minute override' do
      assistant.config['memory_idle_timeout_test_minutes'] = 5
      latest_public_message(10.minutes.ago)

      service = Marine::Memory::ContactNotesService.new(assistant: assistant, conversation: conversation)
      expect(service.send(:idle?)).to be(true)
    end

    it 'treats a fresh 2-minute-old public message as not idle under a 5-minute override' do
      assistant.config['memory_idle_timeout_test_minutes'] = 5
      latest_public_message(2.minutes.ago)

      service = Marine::Memory::ContactNotesService.new(assistant: assistant, conversation: conversation)
      expect(service.send(:idle?)).to be(false)
    end

    it 'keeps the default two-hour eligibility window without an override' do
      latest_public_message(1.hour.ago)

      service = Marine::Memory::ContactNotesService.new(assistant: assistant, conversation: conversation)
      expect(service.send(:idle?)).to be(false)
    end
  end

  describe 'delayed enqueue scheduling' do
    let(:trigger_message) do
      create(:message, conversation: conversation, account: account, inbox: inbox, sender: contact,
                       message_type: :incoming, private: false, content: 'turn')
    end

    def schedule
      job = Marine::Conversation::ResponseBuilderJob.new
      job.instance_variable_set(:@conversation, conversation)
      job.instance_variable_set(:@assistant, assistant)
      job.instance_variable_set(:@trigger_message, trigger_message)
      job.send(:schedule_idle_summary)
      ActiveJob::Base.queue_adapter.enqueued_jobs.last
    end

    around { |example| freeze_time { example.run } }

    it 'schedules the idle summary 5 minutes out under a 5-minute override' do
      assistant.config['memory_idle_timeout_test_minutes'] = 5

      entry = schedule
      expect(entry[:job]).to eq(Marine::Memory::IdleSummaryJob)
      expect(Time.zone.at(entry[:at])).to be_within(1.second).of(5.minutes.from_now)
    end

    it 'schedules the idle summary two hours out by default' do
      entry = schedule
      expect(Time.zone.at(entry[:at])).to be_within(1.second).of(2.hours.from_now)
    end
  end
end
