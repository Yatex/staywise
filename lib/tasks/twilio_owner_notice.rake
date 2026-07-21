namespace :twilio do
  desc "Create the checkout-aware owner notice and submit it for WhatsApp approval"
  task provision_owner_notice_with_checkouts: :environment do
    result = Whatsapp::TwilioContentRegistry.new.provision_and_submit_owner_notice
    approval = result.fetch("approval").to_h
    whatsapp = approval["whatsapp"].presence || approval

    puts "Content SID: #{result.fetch('sid')}"
    puts "Approval status: #{whatsapp['status'].presence || 'submitted'}"
    puts "Rejection reason: #{whatsapp['rejection_reason']}" if whatsapp["rejection_reason"].present?
    puts "TWILIO_OWNER_ESCALATION_NOTICE_CONTENT_SID remains unchanged. Update it only after status is approved."
  end
end

namespace :twilio do
  desc "Create the observer activity link notice and submit it for WhatsApp approval"
  task provision_owner_observer_notice: :environment do
    result = Whatsapp::TwilioContentRegistry.new.provision_and_submit_observer_notice
    approval = result.fetch("approval").to_h
    whatsapp = approval["whatsapp"].presence || approval

    puts "Friendly name: owner_observer_activity_notice_v2"
    puts "Content SID: #{result.fetch('sid')}"
    puts "Approval status: #{whatsapp['status'].presence || 'submitted'}"
    puts "Rejection reason: #{whatsapp['rejection_reason']}" if whatsapp["rejection_reason"].present?
    puts "TWILIO_OWNER_OBSERVER_NOTICE_CONTENT_SID remains unchanged. Set it only after status is approved."
  end
end
