class CheckInsController < ActionController::API
  def create
    appointment = CheckIn.new(Appointment.find(params[:id])).call
    render json: { status: appointment.status }, status: :created
  rescue CheckIn::Refused => e
    render json: { error: e.message }, status: :unprocessable_entity
  end
end
