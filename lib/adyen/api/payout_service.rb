require 'adyen/api/simple_soap_client'
require 'adyen/api/templates/payout_service'

module Adyen
  module API
    # This is the class that maps actions to Adyen’s Payout SOAP service.
    #
    # It’s encouraged to use the shortcut methods on the {API} module.
    # Henceforth, for extensive documentation you should look at the {API} documentation.
    #
    # The most important difference is that you instantiate a {PayoutService} with the parameters
    # that are needed for the call that you will eventually make.
    #
    # @example
    #  payout = Adyen::API::PayoutService.new({
    #    :shopper => {
    #      :email => "user@example.com",
    #      :reference => "example_user_1"
    #    },
    #    :bank => {
    #      :iban => "NL48RABO0132394782",
    #      :bic => "RABONL2U",
    #      :bank_name => 'Rabobank',
    #      :country_code => 'NL',
    #      :owner_name => 'Test Shopper'
    #    }
    #  })
    #  response = payout.store_detail
    #  response.detail_stored? # => true
    #
    class PayoutService < SimpleSOAPClient
      # The Adyen Payout SOAP service endpoint uri.
      ENDPOINT_URI = 'https://pal-%s.adyen.com/pal/servlet/soap/Payout'

      # @see API.store_detail
      def store_detail
        call_webservice_action('storeDetail', store_detail_request_body, StoreDetailResponse)
      end

      private

      def store_detail_request_body
        content = bank_partial
        content << ENABLE_RECURRING_PAYOUT_CONTRACT_PARTIAL
        payout_request_body(content)
      end

      def payout_request_body(content)
        validate_parameters!(:merchant_account)
        content << shopper_partial
        LAYOUT % [@params[:merchant_account], content]
      end

      def bank_partial
        validate_parameters!(:bank => [:iban, :bic, :bank_name, :country_code, :owner_name])
        bank  = @params[:bank].values_at(:iban, :bic, :bank_name, :country_code, :owner_name)
        BANK_PARTIAL % bank
      end

      def shopper_partial
        validate_parameters!(:shopper => [:email, :reference])
        @params[:shopper].map { |k, v| SHOPPER_PARTIALS[k] % v }.join("\n")
      end

      class StoreDetailResponse < Response
        class << self
          # @private
          attr_accessor :request_received_value

          def base_xpath
            '//payout:storeDetailResponse/payout:response'
          end
        end

        response_attrs :psp_reference, :result_code, :recurring_detail_reference

        # This only returns whether or not the request has been successfully received. Check the
        # subsequent notification to see if the payment was actually mutated.
        def success?
          super && params[:response] == self.class.request_received_value
        end

        alias_method :detail_stored?, :success?

        def params
          @params ||= xml_querier.xpath(self.class.base_xpath) do |result|
            {
              :psp_reference              => result.text('./payout:pspReference'),
              :result_code                => result.text('./payout:resultCode'),
              :recurring_detail_reference => result.text('./payout:recurringDetailReference')
            }
          end
        end
      end
    end
  end
end
