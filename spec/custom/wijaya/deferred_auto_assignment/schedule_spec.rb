# frozen_string_literal: true

require 'rails_helper'
require 'yaml'
require 'sidekiq/testing'

RSpec.describe 'Deferred auto-assignment recovery drainer schedule' do
  subject(:entry) do
    YAML.safe_load_file(Rails.root.join('config/schedule.yml'), aliases: true)
        .fetch('wijaya_deferred_assignment_recovery_drainer_job')
  end

  it 'runs the recovery drainer hourly at minute 15 on the scheduled_jobs queue' do
    expect(entry).to eq(
      'cron' => '15 * * * *',
      'class' => 'Wijaya::Batteries::DeferredAutoAssignment::RecoveryDrainerJob',
      'queue' => 'scheduled_jobs',
      'active_job' => true
    )
  end

  it 'dispatches and executes through ActiveJob when cron cannot constantize the Battery job class' do
    executed = false

    allow(Sidekiq::Cron::Support).to receive(:safe_constantize)
      .with('Wijaya::Batteries::DeferredAutoAssignment::RecoveryDrainerJob').and_return(nil)
    allow_any_instance_of(Wijaya::Batteries::DeferredAutoAssignment::RecoveryDrainerJob)
      .to receive(:drain_marker_outbox) { executed = true }
    allow_any_instance_of(Wijaya::Batteries::DeferredAutoAssignment::RecoveryDrainerJob)
      .to receive(:next_run_intent).and_return(nil)
    cron_job = Sidekiq::Cron::Job.new(
      entry.merge('name' => 'deferred-auto-assignment-recovery-acceptance', 'fetch_missing_args' => false)
    )
    allow(cron_job).to receive(:save_last_enqueue_time)
    allow(cron_job).to receive(:add_jid_history)

    Sidekiq::Testing.inline! { cron_job.enqueue! }

    expect(executed).to be(true)
  end
end
