require File.expand_path("../spec_helper", __FILE__)

shared_examples_for "payment requests" do
  it "includes the merchant account handle" do
    text('./payment:merchantAccount').should == 'SuperShopper'
  end

  it "includes the payment reference of the merchant" do
    text('./payment:reference').should == 'order-id'
  end

  it "includes the given amount of `currency'" do
    xpath('./payment:amount') do |amount|
      amount.text('./common:currency').should == 'EUR'
      amount.text('./common:value').should == '1234'
    end
  end

  it "includes the shopper’s details" do
    text('./payment:shopperReference').should == 'user-id'
    text('./payment:shopperEmail').should == 's.hopper@example.com'
    text('./payment:shopperIP').should == '61.294.12.12'
  end

  it "only includes shopper details for given parameters" do
    @payment.params[:shopper].delete(:reference)
    xpath('./payment:shopperReference').should be_empty
    @payment.params[:shopper].delete(:email)
    xpath('./payment:shopperEmail').should be_empty
    @payment.params[:shopper].delete(:ip)
    xpath('./payment:shopperIP').should be_empty
  end

  it "does not include any shopper details if none are given" do
    @payment.params.delete(:shopper)
    xpath('./payment:shopperReference').should be_empty
    xpath('./payment:shopperEmail').should be_empty
    xpath('./payment:shopperIP').should be_empty
  end
end

shared_examples_for "recurring payment requests" do
  it_should_behave_like "payment requests"

  it "obviously includes the obligatory self-‘describing’ nonsense parameters" do
    text('./payment:shopperInteraction').should == 'ContAuth'
  end

  it "uses the latest recurring detail reference, by default" do
    text('./payment:selectedRecurringDetailReference').should == 'LATEST'
  end

  it "uses the given recurring detail reference" do
    @payment.params[:recurring_detail_reference] = 'RecurringDetailReference1'
    text('./payment:selectedRecurringDetailReference').should == 'RecurringDetailReference1'
  end
end

describe Adyen::API::PaymentService do
  include APISpecHelper

  before do
    @params = {
      :reference => 'order-id',
      :amount => {
        :currency => 'EUR',
        :value => '1234',
      },
      :shopper => {
        :email => 's.hopper@example.com',
        :reference => 'user-id',
        :ip => '61.294.12.12',
      },
      :card => {
        :expiry_month => 12,
        :expiry_year => 2012,
        :holder_name => 'Simon わくわく Hopper',
        :number => '4444333322221111',
        :cvc => '737',
        # Maestro UK/Solo only
        #:issue_number => ,
        #:start_month => ,
        #:start_year => ,
      }
    }
    @payment = @object = Adyen::API::PaymentService.new(@params)
  end

  describe "authorise_payment_request_body" do
    before :all do
      @method = :authorise_payment_request_body
    end

    it_should_behave_like "payment requests"

    it "includes the creditcard details" do
      xpath('./payment:card') do |card|
        # there's no reason why Nokogiri should escape these characters, but as long as they're correct
        card.text('./payment:holderName').should == 'Simon &#x308F;&#x304F;&#x308F;&#x304F; Hopper'
        card.text('./payment:number').should == '4444333322221111'
        card.text('./payment:cvc').should == '737'
        card.text('./payment:expiryMonth').should == '12'
        card.text('./payment:expiryYear').should == '2012'
      end
    end

    it "formats the creditcard’s expiry month as a two digit number" do
      @payment.params[:card][:expiry_month] = 6
      text('./payment:card/payment:expiryMonth').should == '06'
    end

    it "includes the necessary recurring and one-click contract info if the `:recurring' param is truthful" do
      xpath('./payment:recurring/payment:contract').should be_empty
      @payment.params[:recurring] = true
      text('./payment:recurring/payment:contract').should == 'RECURRING,ONECLICK'
    end
  end

  describe "authorise_payment" do
    before do
      stub_net_http(AUTHORISE_RESPONSE)
      @response = @payment.authorise_payment
      @request, @post = Net::HTTP.posted
    end

    after do
      Net::HTTP.stubbing_enabled = false
    end

    it "posts the body generated for the given parameters" do
      @post.body.should include(@payment.authorise_payment_request_body)
    end

    it "posts to the correct SOAP action" do
      @post.soap_action.should == 'authorise'
    end

    for_each_xml_backend do
      it "returns a hash with parsed response details" do
        @payment.authorise_payment.params.should == {
          :psp_reference => '9876543210987654',
          :result_code => 'Authorised',
          :auth_code => '1234',
          :refusal_reason => ''
        }
      end
    end

    it_should_have_shortcut_methods_for_params_on_the_response

    describe "with a authorized response" do
      it "returns that the request was authorised" do
        @response.should be_success
        @response.should be_authorized
      end
    end

    describe "with a `declined' response" do
      before do
        stub_net_http(AUTHORISATION_DECLINED_RESPONSE)
        @response = @payment.authorise_payment
      end

      it "returns that the request was not authorised" do
        @response.should_not be_success
        @response.should_not be_authorized
      end
    end

    describe "with a `invalid' response" do
      before do
        stub_net_http(AUTHORISE_REQUEST_INVALID_RESPONSE % 'validation 101 Invalid card number')
        @response = @payment.authorise_payment
      end

      it "returns that the request was not authorised" do
        @response.should_not be_success
        @response.should_not be_authorized
      end

      it "it returns that the request was invalid" do
        @response.should be_invalid_request
      end

      it "returns the fault message from #refusal_reason" do
        @response.refusal_reason.should == 'validation 101 Invalid card number'
        @response.params[:refusal_reason].should == 'validation 101 Invalid card number'
      end

      it "returns creditcard validation errors" do
        [
          ["validation 101 Invalid card number",                           [:number,       'is not a valid creditcard number']],
          ["validation 103 CVC is not the right length",                   [:cvc,          'is not the right length']],
          ["validation 128 Card Holder Missing",                           [:holder_name,  'can’t be blank']],
          ["validation Couldn't parse expiry year",                        [:expiry_year,  'could not be recognized']],
          ["validation Expiry month should be between 1 and 12 inclusive", [:expiry_month, 'could not be recognized']],
        ].each do |message, error|
          response_with_fault_message(message).error.should == error
        end
      end

      it "returns any other fault messages on `base'" do
        message = "validation 130 Reference Missing"
        response_with_fault_message(message).error.should == [:base, message]
      end

      it "prepends the error attribute with the given prefix, except for :base" do
        [
          ["validation 101 Invalid card number", [:card_number, 'is not a valid creditcard number']],
          ["validation 130 Reference Missing",   [:base,        "validation 130 Reference Missing"]],
        ].each do |message, error|
          response_with_fault_message(message).error(:card).should == error
        end
      end

      it "returns the original message corresponding to the given attribute and message" do
        [
          ["validation 101 Invalid card number",                           [:number,       'is not a valid creditcard number']],
          ["validation 103 CVC is not the right length",                   [:cvc,          'is not the right length']],
          ["validation 128 Card Holder Missing",                           [:holder_name,  'can’t be blank']],
          ["validation Couldn't parse expiry year",                        [:expiry_year,  'could not be recognized']],
          ["validation Expiry month should be between 1 and 12 inclusive", [:expiry_month, 'could not be recognized']],
          ["validation 130 Reference Missing",                             [:base,         'validation 130 Reference Missing']],
        ].each do |expected, attr_and_message|
          Adyen::API::PaymentService::AuthorizationResponse.original_fault_message_for(*attr_and_message).should == expected
        end
      end

      private

      def response_with_fault_message(message)
        stub_net_http(AUTHORISE_REQUEST_INVALID_RESPONSE % message)
        @response = @payment.authorise_payment
      end
    end
  end

  describe "authorise_recurring_payment_request_body" do
    before :all do
      @method = :authorise_recurring_payment_request_body
    end

    it_should_behave_like "recurring payment requests"

    it "includes the contract type, which is `RECURRING'" do
      text('./payment:recurring/payment:contract').should == 'RECURRING'
    end

    it "does not include any creditcard details" do
      xpath('./payment:card').should be_empty
    end
  end

  describe "authorise_recurring_payment" do
    before do
      stub_net_http(AUTHORISE_RESPONSE)
      @response = @payment.authorise_recurring_payment
      @request, @post = Net::HTTP.posted
    end

    after do
      Net::HTTP.stubbing_enabled = false
    end

    it "posts the body generated for the given parameters" do
      @post.body.should include(@payment.authorise_recurring_payment_request_body)
    end

    it "posts to the correct SOAP action" do
      @post.soap_action.should == 'authorise'
    end

    for_each_xml_backend do
      it "returns a hash with parsed response details" do
        @payment.authorise_recurring_payment.params.should == {
          :psp_reference => '9876543210987654',
          :result_code => 'Authorised',
          :auth_code => '1234',
          :refusal_reason => ''
        }
      end
    end

    it_should_have_shortcut_methods_for_params_on_the_response
  end

  describe "authorise_one_click_payment_request_body" do
    before :all do
      @method = :authorise_one_click_payment_request_body
    end

    it_should_behave_like "recurring payment requests"

    it "includes the contract type, which is `ONECLICK'" do
      text('./payment:recurring/payment:contract').should == 'ONECLICK'
    end

    it "does includes only the creditcard's CVC code" do
      xpath('./payment:card') do |card|
        card.text('./payment:cvc').should == '737'

        card.xpath('./payment:holderName').should be_empty
        card.xpath('./payment:number').should be_empty
        card.xpath('./payment:expiryMonth').should be_empty
        card.xpath('./payment:expiryYear').should be_empty
      end
    end
  end

  describe "authorise_one_click_payment" do
    before do
      stub_net_http(AUTHORISE_RESPONSE)
      @response = @payment.authorise_one_click_payment
      @request, @post = Net::HTTP.posted
    end

    after do
      Net::HTTP.stubbing_enabled = false
    end

    it "posts the body generated for the given parameters" do
      @post.body.should include(@payment.authorise_one_click_payment_request_body)
    end

    it "posts to the correct SOAP action" do
      @post.soap_action.should == 'authorise'
    end

    for_each_xml_backend do
      it "returns a hash with parsed response details" do
        @payment.authorise_one_click_payment.params.should == {
          :psp_reference => '9876543210987654',
          :result_code => 'Authorised',
          :auth_code => '1234',
          :refusal_reason => ''
        }
      end
    end

    it_should_have_shortcut_methods_for_params_on_the_response
  end

  describe "capture_body" do
    before :all do
      @method = :capture_body
    end

    before do
      @payment.params[:psp_reference] = 'original-psp-reference'
    end

    it "includes the merchant account" do
      text('./payment:merchantAccount').should == 'SuperShopper'
    end

    it "includes the amount to refund" do
      xpath('./payment:modificationAmount') do |amount|
        amount.text('./common:currency').should == 'EUR'
        amount.text('./common:value').should == '1234'
      end
    end

    it "includes the payment (PSP) reference of the payment to refund" do
      text('./payment:originalReference').should == 'original-psp-reference'
    end

    private

    def node_for_current_method
      node_for_current_object_and_method.xpath('//payment:capture/payment:modificationRequest')
    end
  end

  describe "refund_body" do
    before :all do
      @method = :refund_body
    end

    before do
      @payment.params[:psp_reference] = 'original-psp-reference'
    end

    it "includes the merchant account" do
      text('./payment:merchantAccount').should == 'SuperShopper'
    end

    it "includes the amount to refund" do
      xpath('./payment:modificationAmount') do |amount|
        amount.text('./common:currency').should == 'EUR'
        amount.text('./common:value').should == '1234'
      end
    end

    it "includes the payment (PSP) reference of the payment to refund" do
      text('./payment:originalReference').should == 'original-psp-reference'
    end

    private

    def node_for_current_method
      node_for_current_object_and_method.xpath('//payment:refund/payment:modificationRequest')
    end
  end

  describe "capture" do
    before do
      stub_net_http(CAPTURE_RESPONSE % '[capture-received]')
      @response = @payment.capture
      @request, @post = Net::HTTP.posted
    end

    after do
      Net::HTTP.stubbing_enabled = false
    end

    it "posts the body generated for the given parameters" do
      @post.body.should include(@payment.capture_body)
    end

    it "posts to the correct SOAP action" do
      @post.soap_action.should == 'authorise'
    end

    for_each_xml_backend do
      it "returns a hash with parsed response details" do
        @payment.capture.params.should == {
          :psp_reference => '8512867956198946',
          :response => '[capture-received]'
        }
      end
    end

    it_should_have_shortcut_methods_for_params_on_the_response

    describe "with a successful response" do
      it "returns that the request was received successfully" do
        @response.should be_success
      end
    end

    describe "with a failed response" do
      before do
        stub_net_http(CAPTURE_RESPONSE % 'failed')
        @response = @payment.capture
      end

      it "returns that the request was not received successfully" do
        @response.should_not be_success
      end
    end
  end

  describe "refund" do
    before do
      stub_net_http(REFUND_RESPONSE % '[refund-received]')
      @response = @payment.refund
      @request, @post = Net::HTTP.posted
    end

    after do
      Net::HTTP.stubbing_enabled = false
    end

    it "posts the body generated for the given parameters" do
      @post.body.should include(@payment.refund_body)
    end

    it "posts to the correct SOAP action" do
      @post.soap_action.should == 'authorise'
    end

    for_each_xml_backend do
      it "returns a hash with parsed response details" do
        @payment.refund.params.should == {
          :psp_reference => '8512865475512126',
          :response => '[refund-received]'
        }
      end
    end

    it_should_have_shortcut_methods_for_params_on_the_response

    describe "with a successful response" do
      it "returns that the request was received successfully" do
        @response.should be_success
      end
    end

    describe "with a failed response" do
      before do
        stub_net_http(REFUND_RESPONSE % 'failed')
        @response = @payment.refund
      end

      it "returns that the request was not received successfully" do
        @response.should_not be_success
      end
    end
  end

  describe "cancel_or_refund_body" do
    before :all do
      @method = :cancel_or_refund_body
    end

    before do
      @payment.params[:psp_reference] = 'original-psp-reference'
    end

    it "includes the merchant account" do
      text('./payment:merchantAccount').should == 'SuperShopper'
    end

    it "includes the payment (PSP) reference of the payment to refund" do
      text('./payment:originalReference').should == 'original-psp-reference'
    end

    private

    def node_for_current_method
      node_for_current_object_and_method.xpath('//payment:cancelOrRefund/payment:modificationRequest')
    end
  end

  describe "cancel_or_refund" do
    before do
      stub_net_http(CANCEL_OR_REFUND_RESPONSE % '[cancelOrRefund-received]')
      @response = @payment.cancel_or_refund
      @request, @post = Net::HTTP.posted
    end

    after do
      Net::HTTP.stubbing_enabled = false
    end

    it "posts the body generated for the given parameters" do
      @post.body.should include(@payment.cancel_or_refund_body)
    end

    it "posts to the correct SOAP action" do
      @post.soap_action.should == 'authorise'
    end

    for_each_xml_backend do
      it "returns a hash with parsed response details" do
        @payment.cancel_or_refund.params.should == {
          :psp_reference => '8512865521218306',
          :response => '[cancelOrRefund-received]'
        }
      end
    end

    it_should_have_shortcut_methods_for_params_on_the_response

    describe "with a successful response" do
      it "returns that the request was received successfully" do
        @response.should be_success
      end
    end

    describe "with a failed response" do
      before do
        stub_net_http(CANCEL_OR_REFUND_RESPONSE % 'failed')
        @response = @payment.cancel_or_refund
      end

      it "returns that the request was not received successfully" do
        @response.should_not be_success
      end
    end
  end

  describe "cancel_body" do
    before :all do
      @method = :cancel_body
    end

    before do
      @payment.params[:psp_reference] = 'original-psp-reference'
    end

    it "includes the merchant account" do
      text('./payment:merchantAccount').should == 'SuperShopper'
    end

    it "includes the payment (PSP) reference of the payment to refund" do
      text('./payment:originalReference').should == 'original-psp-reference'
    end

    private

    def node_for_current_method
      node_for_current_object_and_method.xpath('//payment:cancel/payment:modificationRequest')
    end
  end

  describe "cancel" do
    before do
      stub_net_http(CANCEL_RESPONSE % '[cancel-received]')
      @response = @payment.cancel
      @request, @post = Net::HTTP.posted
    end

    after do
      Net::HTTP.stubbing_enabled = false
    end

    it "posts the body generated for the given parameters" do
      @post.body.should include(@payment.cancel_body)
    end

    it "posts to the correct SOAP action" do
      @post.soap_action.should == 'authorise'
    end

    for_each_xml_backend do
      it "returns a hash with parsed response details" do
        @payment.cancel.params.should == {
          :psp_reference => '8612865544848013',
          :response => '[cancel-received]'
        }
      end
    end

    it_should_have_shortcut_methods_for_params_on_the_response

    describe "with a successful response" do
      it "returns that the request was received successfully" do
        @response.should be_success
      end
    end

    describe "with a failed response" do
      before do
        stub_net_http(CANCEL_RESPONSE % 'failed')
        @response = @payment.cancel
      end

      it "returns that the request was not received successfully" do
        @response.should_not be_success
      end
    end
  end

  describe "test helpers that stub responses" do
    after do
      Net::HTTP.stubbing_enabled = false
    end

    it "returns an `authorized' response" do
      stub_net_http(AUTHORISATION_DECLINED_RESPONSE)
      Adyen::API::PaymentService.stub_success!
      @payment.authorise_payment.should be_authorized

      @payment.authorise_payment.should_not be_authorized
    end

    it "returns a `refused' response" do
      stub_net_http(AUTHORISE_RESPONSE)
      Adyen::API::PaymentService.stub_refused!
      response = @payment.authorise_payment
      response.should_not be_authorized
      response.should_not be_invalid_request

      @payment.authorise_payment.should be_authorized
    end

    it "returns a `invalid request' response" do
      stub_net_http(AUTHORISE_RESPONSE)
      Adyen::API::PaymentService.stub_invalid!
      response = @payment.authorise_payment
      response.should_not be_authorized
      response.should be_invalid_request

      @payment.authorise_payment.should be_authorized
    end
  end

  private

  def node_for_current_method
    node_for_current_object_and_method.xpath('//payment:authorise/payment:paymentRequest')
  end
end
