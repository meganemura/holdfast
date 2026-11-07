require "rails_helper"

RSpec.describe Appointment do
  it("refuses an unknown status") { expect(build(:appointment, status: "lost")).not_to be_valid }
end
