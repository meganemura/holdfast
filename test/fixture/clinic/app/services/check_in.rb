class CheckIn
  class Refused < StandardError; end

  def initialize(appointment) = @appointment = appointment

  def call
    @appointment.with_lock do
      raise Refused, "appointment is #{@appointment.status}" unless @appointment.status == "booked"

      @appointment.update!(status: "checked_in")
    end
    @appointment
  end
end
