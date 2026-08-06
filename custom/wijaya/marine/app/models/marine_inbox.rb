class MarineInbox < ApplicationRecord
  belongs_to :marine_assistant, class_name: 'Marine::Assistant'
  belongs_to :inbox

  validates :inbox_id, uniqueness: true
end
