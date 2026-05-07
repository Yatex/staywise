account = Account.find_or_create_by!(slug: "demo-stays") do |record|
  record.name = "Demo Stays"
  record.default_ai_instructions = "Be concise, warm, and factual. Only answer using configured Staywise information."
  record.ai_tone = "Friendly and practical"
  record.languages_supported = "English, Spanish"
  record.unsure_behavior = "Tell the guest you will check with the host and create an alert."
  record.emergency_contact_behavior = "Escalate immediately and share configured emergency information when available."
end

user = account.users.find_or_initialize_by(email: "owner@staywise.test")
if user.new_record?
  user.name = "Demo Owner"
  user.password = "password123"
  user.password_confirmation = "password123"
end
user.role = "owner"
user.save!

admin_account = Account.find_or_create_by!(slug: "staywise-admin") do |record|
  record.name = "Staywise Admin"
  record.default_ai_instructions = "Internal Staywise admin account."
end

admin_user = admin_account.users.find_or_initialize_by(email: "admin@staywise.test")
if admin_user.new_record?
  admin_user.name = "Staywise Admin"
  admin_user.password = "password123"
  admin_user.password_confirmation = "password123"
end
admin_user.role = "admin"
admin_user.save!

admin_account.subscriptions.find_or_create_by!(plan: "business") do |subscription|
  subscription.status = "active"
  subscription.current_period_end = 1.year.from_now
end

account.subscriptions.find_or_create_by!(plan: "growth") do |subscription|
  subscription.status = "trialing"
  subscription.trial_ends_at = 14.days.from_now
end

property = account.properties.find_or_create_by!(name: "Rambla Studio") do |record|
  record.internal_nickname = "Ocean View Studio"
  record.address = "Rambla, Montevideo"
  record.check_in_time = "3:00 PM"
  record.checkout_time = "11:00 AM"
  record.wifi_name = "Staywise Guest"
  record.wifi_password = "welcome-home"
  record.house_rules = "No smoking inside. Quiet hours are 10 PM to 8 AM. Please close balcony doors when leaving."
  record.access_instructions = "Use the keypad at the building entrance, then take the elevator to the 6th floor. The lockbox is beside the apartment door."
  record.parking_instructions = "Street parking is usually available nearby. Paid parking is available two blocks away."
  record.emergency_information = "For medical emergencies call local emergency services. The nearest hospital is Hospital Britanico."
  record.owner_contact_instructions = "Escalate late checkout, refund, emergency, and maintenance requests to the host."
  record.ai_general_notes = "Keep replies short and do not invent policies, prices, or availability."
  record.tags = %w[ocean-view studio montevideo]
end
property.update!(tags: (property.tags + %w[ocean-view studio montevideo]).uniq, ai_enabled: true)

property.knowledge_blocks.find_or_create_by!(title: "Check-in steps") do |block|
  block.category = "check_in"
  block.content = "Check-in starts at 3:00 PM. The building keypad code and lockbox details are sent on arrival day."
  block.status = "active"
end

property.knowledge_blocks.find_or_create_by!(title: "WiFi") do |block|
  block.category = "wifi"
  block.content = "Network: Staywise Guest. Password: welcome-home."
  block.status = "active"
end

property.recommendations.find_or_create_by!(name: "Cafe Mercado") do |place|
  place.category = "cafe"
  place.description = "A relaxed cafe with breakfast, espresso, and reliable seating."
  place.address = "Near the waterfront"
  place.distance_or_walking_time = "6 min walk"
  place.owner_note = "Good for a quiet morning coffee."
end

property.faqs.find_or_create_by!(question: "Can I check out late?") do |faq|
  faq.answer = "Late checkout requires host approval. I will check with the host for you."
  faq.category = "checkout"
  faq.active = true
end
