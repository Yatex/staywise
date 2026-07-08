import { sanitizeGuestVisibleText } from "./guest-message-sanitizer.js";

export function ensureSafeFallbackResponse<T extends Record<string, unknown>>(
  decision: T,
  fallbackLanguage?: string,
): T & { safe_fallback_response: string } {
  const current = sanitizeGuestVisibleText(decision.safe_fallback_response);
  if (current) {
    return {
      ...decision,
      safe_fallback_response: current,
    };
  }

  return {
    ...decision,
    safe_fallback_response: safeFallbackResponseFor(
      normalizeLanguage(String(decision.language || "")) || normalizeLanguage(fallbackLanguage) || "en",
    ),
  };
}

export function safeFallbackResponseFor(language?: string) {
  switch (normalizeLanguage(language)) {
    case "es":
      return "No tengo esa información confirmada. Necesito revisarla antes de responderte.";
    case "fr":
      return "Je n'ai pas cette information confirmée. Je dois la vérifier avant de vous répondre.";
    case "de":
      return "Diese Information ist noch nicht bestätigt. Ich muss sie prüfen, bevor ich dir antworte.";
    case "pt":
      return "Não tenho essa informação confirmada. Preciso verificá-la antes de responder.";
    case "it":
      return "Non ho questa informazione confermata. Devo verificarla prima di risponderti.";
    case "zh":
      return "我还没有确认这项信息，需要核实后才能回复你。";
    case "ja":
      return "その情報はまだ確認できていません。確認してから回答します。";
    case "ko":
      return "해당 정보는 아직 확인되지 않았습니다. 확인한 뒤 답변드리겠습니다.";
    case "ar":
      return "ليست لدي هذه المعلومة مؤكدة بعد. أحتاج إلى التحقق منها قبل الرد.";
    case "he":
      return "המידע הזה עדיין לא מאומת. צריך לבדוק אותו לפני שאענה.";
    case "ru":
      return "У меня пока нет подтверждённой информации. Мне нужно проверить её перед ответом.";
    default:
      return "I don't have that information confirmed. I need to review it before replying.";
  }
}

function normalizeLanguage(language?: string) {
  return language?.split(/[-_]/)[0].toLowerCase() || undefined;
}
