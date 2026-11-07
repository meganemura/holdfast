module PaymentGateway
  class << self
    attr_writer :client

    def client = @client || raise("no payment client configured")
  end
end
