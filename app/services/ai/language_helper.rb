module AI
  module LanguageHelper
    module_function

    def detect(text, fallback: nil)
      value = text.to_s
      return normalize_code(fallback) if value.blank?

      return "zh" if value.match?(/[\p{Han}]/)
      return "ja" if value.match?(/[\p{Hiragana}\p{Katakana}]/)
      return "ko" if value.match?(/[\p{Hangul}]/)
      return "ar" if value.match?(/[\p{Arabic}]/)
      return "he" if value.match?(/[\p{Hebrew}]/)
      return "ru" if value.match?(/[\p{Cyrillic}]/)

      normalized = value.downcase
      return "es" if normalized.match?(/\b(y|el|la|los|las|un|una|del|de|mi|tu|para)\b.*\bcheck\s*-?\s*out\b/)
      return "es" if normalized.match?(/\bcheck\s*-?\s*out\b.*\b(y|el|la|los|las|un|una|del|de|mi|tu|para)\b/)
      return "es" if normalized.match?(/\b(qué|que|dónde|donde|cuándo|cuando|cómo|como|hola|gracias|necesito|puedo|quisiera|quiero|saber|salida|entrada|red|clave|contraseña|contrasena|anfitri[oó]n|pasar[ií]as|dir[ií]as|gu[ií]a|llegar|edificio)\b/)
      return "fr" if normalized.match?(/\b(bonjour|merci|où|ou|quand|comment|puis-je|hôte|hote|propriétaire|proprietaire)\b/)
      return "de" if normalized.match?(/\b(hallo|danke|wo|wann|wie|kann ich|gastgeber|vermieter)\b/)
      return "pt" if normalized.match?(/\b(olá|ola|obrigado|obrigada|onde|quando|como|posso|anfitrião|anfitriao)\b/)
      return "it" if normalized.match?(/\b(ciao|grazie|dove|quando|come|posso|host|proprietario)\b/)

      "en"
    end

    def owner_language(account)
      normalize_code(account&.ai_preferred_language).presence || "es"
    end

    def safe_ack_for(text, fallback_language: nil)
      case detect(text, fallback: fallback_language)
      when "es"
        "Gracias por tu mensaje. Lo estoy consultando con el anfitrión y te responderé en breve."
      when "fr"
        "Merci pour votre message. Je vérifie cela avec l'hôte et je vous répondrai bientôt."
      when "de"
        "Danke für deine Nachricht. Ich kläre das mit dem Gastgeber und melde mich in Kürze."
      when "pt"
        "Obrigado pela mensagem. Vou verificar isso com o anfitrião e respondo em breve."
      when "it"
        "Grazie per il messaggio. Verifico con l'host e ti rispondo a breve."
      when "zh"
        "谢谢你的消息。我会向房东确认，并尽快回复你。"
      when "ja"
        "メッセージありがとうございます。ホストに確認して、できるだけ早く返信します。"
      when "ko"
        "메시지 감사합니다. 호스트에게 확인한 뒤 곧 답변드리겠습니다."
      when "ar"
        "شكرًا على رسالتك. سأتحقق من ذلك مع المضيف وأرد عليك قريبًا."
      when "he"
        "תודה על ההודעה. אבדוק זאת מול המארח ואחזור אליך בקרוב."
      when "ru"
        "Спасибо за сообщение. Я уточню это у хозяина и скоро отвечу."
      else
        "Thanks for your message. I'm checking this with the host and will get back to you shortly."
      end
    end

    def emergency_ack_for(text, fallback_language: nil)
      case detect(text, fallback: fallback_language)
      when "es"
        "Si alguien está en peligro inmediato, contactá ahora a los servicios de emergencia locales. También estoy avisando al anfitrión."
      when "fr"
        "Si quelqu'un est en danger immédiat, contactez les services d'urgence locaux maintenant. Je préviens aussi l'hôte."
      when "de"
        "Wenn jemand unmittelbar in Gefahr ist, kontaktiere bitte sofort den örtlichen Notdienst. Ich informiere auch den Gastgeber."
      when "pt"
        "Se alguém estiver em perigo imediato, contacte agora os serviços de emergência locais. Também estou avisando o anfitrião."
      when "it"
        "Se qualcuno è in pericolo immediato, contatta subito i servizi di emergenza locali. Sto avvisando anche l'host."
      when "zh"
        "如果有人正处于紧急危险中，请立即联系当地紧急服务。我也会通知房东。"
      else
        "If anyone is in immediate danger, please contact local emergency services now. I am also notifying the host."
      end
    end

    def intro_reply_for(property, text, fallback_language: nil)
      multilingual_welcome
    end

    def multilingual_welcome
      "👋 Hola, soy Ayla, tu asistente.\n\n" \
        "🇪🇸 Escribí en español.\n" \
        "🇬🇧 Write in English.\n" \
        "🇧🇷 Escreva em português.\n\n" \
        "💬 También puedo entender muchos otros idiomas."
    end

    def conversational_reply_for(text, fallback_language: nil)
      normalized = ActiveSupport::Inflector.transliterate(text.to_s)
        .downcase
        .gsub(/[^\p{Alnum}\s]+/, " ")
        .squish
      language = detect(text, fallback: fallback_language)

      if normalized.match?(/\b(chau|chao|hasta luego|bye|goodbye|see you|tchau|ate logo)\b/)
        return language == "en" ? "Goodbye. Let me know if you need anything else." : language == "pt" ? "Até logo. Se precisar de algo mais, é só me avisar." : "Hasta luego. Cualquier cosa escribime."
      end

      if normalized.match?(/\b(gracias|muchas gracias|thanks|thank you|obrigado|obrigada)\b/)
        return language == "en" ? "You're welcome. Let me know if you need anything else." : language == "pt" ? "De nada. Se precisar de algo mais, é só me avisar." : "De nada. Avisame si necesitás algo más."
      end

      if normalized.match?(/\b(ok|okay|dale|listo|perfecto|entendido|genial|excelente|perfect|great|got it|perfeito|entendi|beleza)\b/) &&
          !normalized.match?(/\b(hola|buenas|hello|hi|hey|ola|bom dia|boa tarde|boa noite)\b/)
        return language == "en" ? "Perfect, let me know if you need anything else." : language == "pt" ? "Perfeito, qualquer coisa é só me escrever." : "Perfecto, cualquier cosa escribime."
      end

      if language == "en"
        return "Good afternoon. How can I help?" if normalized.include?("good afternoon")
        return "Good evening. How can I help?" if normalized.match?(/\bgood (evening|night)\b/)
        return "Good morning. How can I help?" if normalized.include?("good morning")
        return "Hi, how can I help?"
      end

      if language == "pt"
        return "Boa tarde. Como posso ajudar?" if normalized.include?("boa tarde")
        return "Boa noite. Como posso ajudar?" if normalized.include?("boa noite")
        return "Bom dia. Como posso ajudar?" if normalized.include?("bom dia")
        return "Olá, como posso ajudar?"
      end

      return "Hola, buenas tardes. ¿En qué puedo ayudarte?" if normalized.include?("buenas tardes")
      return "Buenas noches. ¿En qué puedo ayudarte?" if normalized.include?("buenas noches")
      return "Buen día. ¿En qué puedo ayudarte?" if normalized.match?(/\bbuen(os)? dia(s)?\b/)

      "Hola, ¿en qué puedo ayudarte?"
    end

    def ambiguous_time_reply_for(text, fallback_language: nil)
      case detect(text, fallback: fallback_language)
      when "es"
        "¿Te referís al horario de check-in para llegar, o al horario de checkout para irte?"
      when "fr"
        "Vous parlez de l'heure d'arrivée pour le check-in, ou de l'heure de départ pour le checkout ?"
      when "de"
        "Meinst du die Check-in-Zeit zum Ankommen oder die Checkout-Zeit zum Abreisen?"
      when "pt"
        "Você quer saber o horário de check-in para chegar ou o horário de checkout para sair?"
      when "it"
        "Intendi l'orario di check-in per arrivare o l'orario di checkout per partire?"
      when "zh"
        "你是想问入住可以几点到，还是退房最晚几点离开？"
      when "ja"
        "到着できるチェックイン時間のことですか、それともチェックアウトで出発する時間のことですか？"
      when "ko"
        "도착 가능한 체크인 시간을 말씀하시는 건가요, 아니면 퇴실해야 하는 체크아웃 시간을 말씀하시는 건가요?"
      when "ar"
        "هل تقصد وقت تسجيل الوصول للوصول، أم وقت تسجيل المغادرة للمغادرة؟"
      when "he"
        "הכוונה לשעת הצ'ק-אין להגעה, או לשעת הצ'ק-אאוט לעזיבה?"
      when "ru"
        "Вы имеете в виду время заезда, когда можно приехать, или время выезда?"
      else
        "Do you mean what time you can arrive for check-in, or what time you need to leave for checkout?"
      end
    end

    def human_handoff_ack_for(text, fallback_language: nil)
      case detect(text, fallback: fallback_language)
      when "es"
        "Claro. Ya envié tu solicitud al anfitrión para que pueda responderte directamente por este chat."
      when "fr"
        "Bien sûr. J'ai transmis votre demande à l'hôte pour qu'il puisse vous répondre directement dans cette conversation."
      when "de"
        "Natürlich. Ich habe deine Anfrage an den Gastgeber weitergeleitet, damit er direkt in diesem Chat antworten kann."
      when "pt"
        "Claro. Já enviei sua solicitação ao anfitrião para que ele possa responder diretamente por este chat."
      when "it"
        "Certo. Ho inviato la tua richiesta all'host, così potrà risponderti direttamente in questa chat."
      else
        "Of course. I have sent your request to the host so they can reply directly in this chat."
      end
    end

    def not_confirmed_no_alert_reply_for(text, fallback_language: nil)
      case detect(text, fallback: fallback_language)
      when "es"
        "No tengo esa información confirmada en este momento. Puedo pedirle al anfitrión que la revise."
      when "fr"
        "Je n'ai pas cette information confirmée pour le moment. Je peux demander à l'hôte de la vérifier."
      when "de"
        "Ich habe diese Information im Moment nicht bestätigt. Ich kann den Gastgeber bitten, sie zu prüfen."
      when "pt"
        "Não tenho essa informação confirmada no momento. Posso pedir ao anfitrião que verifique."
      when "it"
        "Al momento non ho questa informazione confermata. Posso chiedere all'host di verificarla."
      else
        "I do not have confirmed information about that right now. I can ask the host to review it."
      end
    end

    def fact_reply_for(field, value, text, fallback_language: nil)
      case detect(text, fallback: fallback_language)
      when "es"
        case field.to_s
        when "check_in_time"
          "El check-in es a las #{value}."
        when "check_out_time"
          "El checkout es a las #{value}. Si necesitás salir más tarde, puedo consultarlo con el anfitrión."
        when "address"
          "La dirección es: #{value}."
        when "parking"
          "Sobre el estacionamiento: #{value}"
        when "rules"
          "Estas son las reglas de la casa: #{value}"
        else
          value.to_s
        end
      else
        case field.to_s
        when "check_in_time"
          "Check-in is at #{value}."
        when "check_out_time"
          "Checkout is at #{value}. If you need a later checkout, I can check with the host."
        when "address"
          "The address is: #{value}."
        when "parking"
          "For parking: #{value}"
        when "rules"
          "Here are the house rules: #{value}"
        else
          value.to_s
        end
      end
    end

    def wifi_reply_for(name:, password:, text:, fallback_language: nil)
      case detect(text, fallback: fallback_language)
      when "es"
        if name.present? && password.present?
          "La red de WiFi es #{name} y la contraseña es #{password}."
        elsif name.present?
          "La red de WiFi es #{name}."
        else
          "La contraseña de WiFi es #{password}."
        end
      else
        if name.present? && password.present?
          "The WiFi network is #{name} and the password is #{password}."
        elsif name.present?
          "The WiFi network is #{name}."
        else
          "The WiFi password is #{password}."
        end
      end
    end

    def with_owner_disclosure(response_text, text: nil, fallback_language: nil)
      [response_text, owner_disclosure_for(text.presence || response_text, fallback_language: fallback_language)].join("\n\n")
    end

    def owner_disclosure_for(text, fallback_language: nil)
      case detect(text, fallback: fallback_language)
      when "es"
        "Tené en cuenta que este chat está compartido con el dueño de la propiedad."
      when "fr"
        "Veuillez noter que cette conversation est partagée avec le propriétaire du logement."
      when "de"
        "Bitte beachte, dass dieser Chat mit dem Eigentümer der Unterkunft geteilt wird."
      when "pt"
        "Tenha em conta que esta conversa é compartilhada com o proprietário da acomodação."
      when "it"
        "Tieni presente che questa chat è condivisa con il proprietario dell'alloggio."
      when "zh"
        "请注意，此聊天会与房源业主共享。"
      when "ja"
        "このチャットは宿泊施設のオーナーにも共有されます。"
      when "ko"
        "이 채팅은 숙소 소유자와 공유됩니다."
      when "ar"
        "يرجى العلم أن هذه المحادثة تتم مشاركتها مع مالك العقار."
      when "he"
        "לתשומת ליבך, הצ'אט הזה משותף עם בעל הנכס."
      when "ru"
        "Обратите внимание: этот чат доступен владельцу объекта."
      else
        "Please note that this chat is shared with the property owner."
      end
    end

    def normalize_code(value)
      value.to_s.split(/[-_]/).first.presence
    end
  end
end
