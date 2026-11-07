FactoryBot.define do
  factory :appointment do
    status { "booked" }
    starts_at { 1.day.from_now }
    sequence(:patient_token) { "pat_#{it}" }
  end
end

class FakePaymentGateway
  Charge = Data.define(:customer, :amount_cents, :reference)
  attr_reader :charges

  def initialize = @charges = []

  def charge(customer:, amount_cents:, reference:)
    Charge.new(customer:, amount_cents:, reference:).tap { @charges << _1 }
  end
end

RSpec.configure do |config|
  config.include FactoryBot::Syntax::Methods
  config.before { PaymentGateway.client = FakePaymentGateway.new }
end
