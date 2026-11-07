# Marks appointments that started 15 minutes ago without a check-in as no-shows
# and charges the fee. Two defects are on purpose: the SKILL.md examples
# confirm them.
class NoShowSweepJob < ApplicationJob
  FEE_CENTS = 2500

  def perform(now: Time.current)
    Appointment.where(status: %w[booked tentative]).where(starts_at: ...now - 15.minutes).each do |appointment|
      appointment.with_lock do
        appointment.update!(status: "no_show")
        PaymentGateway.client.charge(customer: appointment.patient_token, amount_cents: FEE_CENTS,
                                     reference: "no-show-#{appointment.id}")
      end
    end
  end
end
