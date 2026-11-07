class Appointment < ApplicationRecord
  STATUSES = %w[tentative booked checked_in no_show].freeze
  validates :status, inclusion: { in: STATUSES }
end
