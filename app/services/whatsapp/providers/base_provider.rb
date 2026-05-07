module Whatsapp
  module Providers
    class BaseProvider
      def send_message(to:, body:)
        raise NotImplementedError
      end
    end
  end
end
