# frozen_string_literal: true

require 'rails_helper'
require 'yaml'
require 'sidekiq/testing'

RSpec.describe 'Marine memory checkpoint schedule' do
  subject(:entry) do
    YAML.safe_load_file(Rails.root.join('config/schedule.yml'), aliases: true)
        .fetch('wijaya_marine_memory_checkpoint_job')
  end

  it 'runs the battery checkpoint at 02:00 Asia/Jakarta on the low queue' do
    expect(entry).to include(
      'cron' => '0 2 * * * Asia/Jakarta',
      'class' => 'Marine::Memory::CheckpointJob',
      'queue' => 'low',
      'active_job' => true
    )
    expect(Fugit::Cron.parse(entry.fetch('cron')).zone).to eq('Asia/Jakarta')
  end

  it 'dispatches and executes through the scheduler when it cannot constantize the job class' do
    relation = instance_double(ActiveRecord::Relation)

    allow(Sidekiq::Cron::Support).to receive(:safe_constantize)
      .with('Marine::Memory::CheckpointJob').and_return(nil)
    cron_job = Sidekiq::Cron::Job.new(
      entry.merge('name' => 'marine-memory-checkpoint-acceptance', 'fetch_missing_args' => false)
    )
    allow(cron_job).to receive(:save_last_enqueue_time)
    allow(cron_job).to receive(:add_jid_history)
    allow(MarineInbox).to receive(:includes).with(:marine_assistant, :inbox).and_return(relation)
    allow(relation).to receive(:find_each)

    Sidekiq::Testing.inline! { cron_job.enqueue! }

    expect(relation).to have_received(:find_each).once
  end
end
