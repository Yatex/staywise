# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn,
  :authorization, :access_code, :door_code, :lockbox_code, :wifi_password,
  :decision_context_id, :prompt, :guest_message, :message_body, :tool_response,
  :evidence, :reservation
]
