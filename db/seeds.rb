account = Account.find_or_create_by!(slug: "demo-stays") do |record|
  record.name = "Demo Stays"
  record.default_ai_instructions = "Sé breve, cálida y factual. Respondé solo con información configurada en Ayla Manager."
  record.ai_tone = "Amigable y práctico"
  record.languages_supported = "Español, Inglés"
  record.unsure_behavior = "Decile al huésped que vas a consultar con el anfitrión y creá una alerta."
  record.emergency_contact_behavior = "Escalá inmediatamente y compartí la información de emergencia configurada cuando esté disponible."
  record.ai_preferred_language = "es"
end
account.update!(
  name: "Demo Stays",
  default_ai_instructions: "Sé breve, cálida y factual. Respondé solo con información configurada en Ayla Manager.",
  ai_tone: "Amigable y práctico",
  languages_supported: "Español, Inglés",
  unsure_behavior: "Decile al huésped que vas a consultar con el anfitrión y creá una alerta.",
  emergency_contact_behavior: "Escalá inmediatamente y compartí la información de emergencia configurada cuando esté disponible.",
  ai_preferred_language: "es"
)

user = account.users.find_or_initialize_by(email: "owner@ayla.test")
user.name = "Propietaria Demo"
if user.new_record?
  user.password = "password123"
  user.password_confirmation = "password123"
end
user.role = "owner"
user.save!

admin_account = Account.find_or_create_by!(slug: "ayla-admin") do |record|
  record.name = "Administrador Ayla"
  record.default_ai_instructions = "Cuenta interna de administración de Ayla Manager."
end
admin_account.update!(
  name: "Administrador Ayla",
  default_ai_instructions: "Cuenta interna de administración de Ayla Manager.",
  ai_preferred_language: "es"
)

admin_user = admin_account.users.find_or_initialize_by(email: "admin@ayla.test")
admin_user.name = "Administrador Ayla"
if admin_user.new_record?
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

def upsert_property(account, name, attributes)
  property = account.properties.find_or_initialize_by(name: name)
  property.assign_attributes(attributes)
  property.save!
  property
end

def upsert_knowledge_block(property, title, attributes)
  block = property.knowledge_blocks.find_or_initialize_by(title: title)
  block.assign_attributes(attributes)
  block.save!
  block
end

def upsert_recommendation(property, name, attributes)
  recommendation = property.recommendations.find_or_initialize_by(name: name)
  recommendation.assign_attributes(attributes)
  recommendation.save!
  recommendation
end

def upsert_faq(property, question, attributes)
  faq = property.faqs.find_or_initialize_by(question: question)
  faq.assign_attributes(attributes)
  faq.save!
  faq
end

def upsert_guest(account, phone_number, attributes)
  guest = account.guests.find_or_initialize_by(phone_number: phone_number)
  guest.assign_attributes(attributes)
  guest.save!
  guest
end

def upsert_conversation(guest, property, attributes = {})
  conversation = property.conversations.find_or_initialize_by(guest: guest)
  conversation.assign_attributes({ status: "active", ai_enabled: true }.merge(attributes))
  conversation.save!
  conversation
end

def create_message_once(conversation, sender, body, created_at)
  conversation.messages.find_or_create_by!(sender: sender, body: body) do |message|
    message.channel = "whatsapp"
    message.created_at = created_at
    message.updated_at = created_at
  end
end

def upsert_alert(property, title, attributes)
  alert = property.alerts.find_or_initialize_by(title: title)
  alert.assign_attributes(attributes)
  alert.save!
  alert
end

rambla = upsert_property(
  account,
  "Rambla Studio",
  internal_nickname: "Estudio con vista al mar",
  address: "Rambla, Montevideo",
  check_in_time: "3:00 PM",
  checkout_time: "11:00 AM",
  wifi_name: "Ayla Guest",
  wifi_password: "welcome-home",
  house_rules: "No se permite fumar dentro. El horario de silencio es de 22:00 a 8:00. Cerrá las puertas del balcón al salir.",
  access_instructions: "Usá el teclado en la entrada del edificio y luego subí en ascensor al piso 6. La caja de llaves está junto a la puerta del apartamento.",
  parking_instructions: "Suele haber estacionamiento en la calle cerca. Hay parking pago a dos cuadras.",
  emergency_information: "Para emergencias médicas llamá a los servicios locales. El hospital más cercano es el Hospital Británico.",
  owner_contact_instructions: "Escalar late checkout, reembolsos, emergencias y pedidos de mantenimiento al anfitrión.",
  ai_general_notes: "Mantener respuestas breves y no inventar políticas, precios ni disponibilidad.",
  tags: %w[ocean-view studio montevideo],
  ai_enabled: true
)

cordon = upsert_property(
  account,
  "Cordon Loft",
  internal_nickname: "Loft urbano cerca de la Universidad",
  address: "Canelones 1620, Montevideo",
  check_in_time: "2:00 PM",
  checkout_time: "10:00 AM",
  wifi_name: "Cordon Loft",
  wifi_password: "loft-guest-2026",
  house_rules: "No se permiten fiestas. Mantener bajo el ruido en pasillos después de las 21:00. No se aceptan mascotas salvo aprobación previa.",
  access_instructions: "Entrá por el portón negro sobre Canelones. El código de la cerradura inteligente se envía 24 horas antes de la llegada.",
  parking_instructions: "No incluye estacionamiento. Recomendar Parking Centro en Constituyente para estadías nocturnas.",
  emergency_information: "El botiquín está debajo del lavatorio del baño. Emergencias: 911. Farmacia más cercana: Farmashop, a 3 cuadras.",
  owner_contact_instructions: "Escalar pérdida de llaves, problemas de mantenimiento, reembolsos y pedidos de dejar equipaje temprano.",
  ai_general_notes: "Responder en español por defecto salvo que el huésped escriba en otro idioma.",
  tags: %w[loft city-center business],
  ai_enabled: true
)

pocitos = upsert_property(
  account,
  "Pocitos Family Apartment",
  internal_nickname: "Dos dormitorios junto al parque",
  address: "Bulevar Espana 2850, Montevideo",
  check_in_time: "4:00 PM",
  checkout_time: "11:00 AM",
  wifi_name: "Pocitos Family",
  wifi_password: "family-stay",
  house_rules: "Las familias son bienvenidas. El horario de silencio es de 22:00 a 8:00. Usar el balcón solo hasta las 23:00.",
  access_instructions: "El portero tiene el sobre con el nombre del huésped. Mostrar documento e ir al apartamento 803.",
  parking_instructions: "Incluye un lugar de garaje. Usar la cochera 18 y dejar el control remoto en el cajón de la cocina.",
  emergency_information: "Hospital más cercano: Asociación Española. El extintor está junto a la puerta de la cocina.",
  owner_contact_instructions: "Escalar problemas con el control del garaje, pedidos de cuna y cualquier queja del edificio.",
  ai_general_notes: "Priorizar información práctica para familias y ser clara con las reglas del edificio.",
  tags: %w[family parking pocitos],
  ai_enabled: true
)

[
  [rambla, "Pasos de check-in", "check_in", "El check-in empieza a las 15:00. El código del teclado del edificio y los datos de la caja de llaves se envían el día de llegada."],
  [rambla, "WiFi", "wifi", "Red: Ayla Guest. Contraseña: welcome-home."],
  [rambla, "Balcón y ventanas", "house_rules", "Cerrar puertas del balcón y ventanas antes de salir porque el viento del río puede ser fuerte."],
  [rambla, "Cómo moverse", "transportation", "La parada de bus sobre la Rambla conecta con Ciudad Vieja, Pocitos y Tres Cruces. Para apps de transporte, el mejor punto de encuentro es la esquina."],
  [cordon, "Cerradura inteligente", "building_access", "Tocá el teclado, ingresá el código temporal y presioná el botón de confirmación. El código vence al checkout."],
  [cordon, "Lavado", "amenities", "El lavarropas-secadora está dentro del placard. Usar el ciclo rápido para cargas pequeñas y vaciar el filtro de pelusa después de secar."],
  [cordon, "Basura", "custom_notes", "Los contenedores están detrás del portón de planta baja. El reciclaje va en el contenedor verde afuera del edificio."],
  [pocitos, "Acceso al garaje", "building_access", "Usar la cochera 18. El control remoto está en el cajón de la cocina y debe devolverse antes del checkout."],
  [pocitos, "Cuna", "amenities", "Se puede preparar una cuna plegable si el huésped la pide al menos 24 horas antes de la llegada."],
  [pocitos, "Checklist de checkout", "checkout", "Dejar las llaves y el control del garaje sobre la mesa del comedor, apagar el aire acondicionado y cerrar las puertas del balcón."]
].each do |property, title, category, content|
  upsert_knowledge_block(property, title, category: category, content: content, status: "active")
end

[
  [rambla, "Café Mercado", "cafe", "Café tranquilo con desayuno, espresso y mesas cómodas.", "Cerca de la rambla", "6 min caminando", "Buena opción para un café tranquilo de mañana."],
  [rambla, "La Barra Market", "supermarket", "Mercado pequeño con básicos, agua, snacks y protector solar.", "Esquina de la Rambla", "4 min caminando", "Abre hasta tarde la mayoría de las noches."],
  [rambla, "Hospital Británico", "pharmacy", "Zona médica confiable más cercana para urgencias y farmacias cercanas.", "Av. Italia", "8 min en auto", "Compartir solo para preguntas relacionadas con salud."],
  [cordon, "Toledo Café", "cafe", "Buen desayuno, pastelería y mesas cómodas para trabajar.", "Canelones 1600", "3 min caminando", "Mejor opción antes de las 11:00."],
  [cordon, "Parking Centro", "transport", "Parking techado pago con tarifas nocturnas.", "Constituyente 1745", "5 min caminando", "Mencionar que no hay estacionamiento incluido."],
  [cordon, "Mercado Ferrando", "restaurant", "Mercado gastronómico con varias opciones para cenar y ambiente casual.", "Chaná 2120", "10 min caminando", "Recomendación fácil para grupos."],
  [pocitos, "Heladería Pecas", "restaurant", "Heladería familiar con postres simples.", "Cerca del Parque Rodó", "7 min caminando", "Muy buena con niños."],
  [pocitos, "Disco Fresh Market", "supermarket", "Supermercado grande para compras y básicos de la casa.", "Bulevar España", "5 min caminando", "Recomendar para estadías largas."],
  [pocitos, "Rambla Pocitos", "attraction", "Paseo fácil para atardecer, correr y acceder a la playa.", "Rambla República del Perú", "12 min caminando", "Tip local simple y de bajo esfuerzo."]
].each do |property, name, category, description, address, distance, owner_note|
  upsert_recommendation(property, name, category: category, description: description, address: address, distance_or_walking_time: distance, owner_note: owner_note)
end

[
  [rambla, "¿Puedo hacer late checkout?", "El late checkout requiere aprobación del anfitrión. Lo consulto por vos.", "checkout"],
  [rambla, "¿Dónde puedo dejar valijas antes del check-in?", "No hay guardado de equipaje dentro del edificio antes del check-in. El anfitrión puede sugerir lugares cercanos si hace falta.", "check_in"],
  [rambla, "¿Se puede fumar en el balcón?", "No se permite fumar dentro. Fumar en el balcón no se recomienda y los huéspedes deben cerrar las puertas para que no entre humo al apartamento.", "house_rules"],
  [cordon, "¿Puedo estacionar cerca?", "El estacionamiento no está incluido. Parking Centro sobre Constituyente es la opción paga recomendada para dejar el auto de noche.", "transport"],
  [cordon, "¿Cómo uso el lavarropas-secadora?", "Usá el ciclo rápido para cargas pequeñas y vaciá el filtro de pelusa después de secar.", "amenities"],
  [cordon, "¿Puedo llevar una mascota?", "Las mascotas requieren aprobación antes de reservar. Lo consulto con el anfitrión si la reserva no incluye aprobación.", "house_rules"],
  [pocitos, "¿Hay cuna?", "Se puede preparar una cuna plegable con 24 horas de aviso. Consulto disponibilidad con el anfitrión.", "amenities"],
  [pocitos, "¿Dónde está la cochera?", "Usá la cochera 18. El control remoto está en el cajón de la cocina y debe devolverse antes del checkout.", "parking"],
  [pocitos, "¿Podemos invitar familia a cenar?", "Las visitas chicas suelen estar bien, pero no se permiten fiestas ni ruido tarde. El horario de silencio del edificio empieza a las 22:00.", "house_rules"]
].each do |property, question, answer, category|
  upsert_faq(property, question, answer: answer, category: category, active: true)
end

sofia = upsert_guest(
  account,
  "+59891234001",
  property: rambla,
  name: "Sofia Alvarez",
  language: "es",
  reservation_reference: "AIR-RAM-1042",
  check_in_date: Date.current - 1.day,
  checkout_date: Date.current + 2.days
)

martin = upsert_guest(
  account,
  "+59891234002",
  property: cordon,
  name: "Martin Pereira",
  language: "es",
  reservation_reference: "AIR-COR-7741",
  check_in_date: Date.current,
  checkout_date: Date.current + 4.days
)

emily = upsert_guest(
  account,
  "+14155550135",
  property: pocitos,
  name: "Emily Carter",
  language: "en",
  reservation_reference: "AIR-POC-2209",
  check_in_date: Date.current + 3.days,
  checkout_date: Date.current + 8.days
)

sofia_thread = upsert_conversation(sofia, rambla, status: "escalated")
create_message_once(sofia_thread, "guest", "Hola, podemos salir a las 13 en vez de las 11?", 3.hours.ago)
create_message_once(sofia_thread, "ai", "El checkout es a las 11:00 AM. Para salir mas tarde necesito confirmarlo con el propietario.", 3.hours.ago + 1.minute)

martin_thread = upsert_conversation(martin, cordon, status: "active")
create_message_once(martin_thread, "guest", "Cual es la clave del WiFi y donde tiro la basura?", 2.hours.ago)
create_message_once(martin_thread, "ai", "La red es Cordon Loft y la clave es loft-guest-2026. La basura va en los contenedores detras del porton de planta baja.", 2.hours.ago + 1.minute)

emily_thread = upsert_conversation(emily, pocitos, status: "escalated")
create_message_once(emily_thread, "guest", "Hi, can you set up a crib before we arrive?", 45.minutes.ago)
create_message_once(emily_thread, "ai", "A folding crib can usually be prepared with 24 hours notice. I will confirm availability with the host.", 44.minutes.ago)

upsert_alert(
  rambla,
  "Pedido de late checkout de Sofía",
  guest: sofia,
  conversation: sofia_thread,
  alert_type: "late_checkout_request",
  description: "La huésped pidió salir a las 13:00 en vez del checkout configurado de las 11:00.",
  status: "open",
  priority: "medium",
  ai_suggested_action: "Aprobar solo si la limpieza puede empezar después de las 13:00; si no, ofrecer guardado de equipaje cercano."
)

upsert_alert(
  pocitos,
  "Pedido de cuna para próxima estadía familiar",
  guest: emily,
  conversation: emily_thread,
  alert_type: "owner_approval_required",
  description: "La huésped pidió una cuna plegable antes de llegar.",
  status: "in_progress",
  priority: "high",
  ai_suggested_action: "Confirmar disponibilidad de cuna y avisarle a la huésped antes del check-in."
)

upsert_alert(
  cordon,
  "Recordatorio de filtro del lavarropas-secadora",
  guest: martin,
  conversation: martin_thread,
  alert_type: "maintenance_issue",
  description: "El huésped preguntó por lavado; revisar el filtro de pelusa después del checkout porque esta unidad recibe consultas frecuentes sobre el lavarropas-secadora.",
  status: "resolved",
  priority: "low",
  ai_suggested_action: "Agregar una etiqueta impresa pequeña dentro del placard de lavado."
)

upsert_alert(
  cordon,
  "Duda nueva: licuadora en cocina",
  guest: martin,
  conversation: martin_thread,
  alert_type: "unknown_question",
  description: "¿Hay licuadora en la cocina?",
  status: "open",
  priority: "medium",
  ai_suggested_action: "Si no requiere una acción física, guardá la respuesta como FAQ para que la IA pueda responderla la próxima vez."
)
