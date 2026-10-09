# frozen_string_literal: true

require 'rails_helper'
require 'yaml'

RSpec.describe 'Marine memory checkpoint schedule' do
  subject(:entry) do
    YAML.safe_load_file(Rails.root.join('config/schedule.yml'), aliases: true)
        .fetch('wijaya_marine_memory_checkpoint_job')
  end

  it 'runs the battery checkpoint at 02:00 Asia/Jakarta on the low queue' do
    expect(entry).to include(
      'cron' => '0 2 * * * Asia/Jakarta',
      'class' => 'Marine::Memory::CheckpointJob',
      'queue' => 'low'
    )
    expect(Fugit::Cron.parse(entry.fetch('cron')).zone).to eq('Asia/Jakarta')
  end
end
