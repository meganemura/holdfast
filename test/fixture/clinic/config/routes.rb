Rails.application.routes.draw do
  post "/appointments/:id/check_in", to: "check_ins#create"
end
