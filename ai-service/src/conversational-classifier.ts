export type ConversationalClassification = {
  kind: "greeting" | "thanks" | "acknowledgement" | "goodbye" | "small_talk";
  language: "es" | "en" | "pt";
  response: string;
};

const SOCIAL_TOKENS = new Set([
  "a",
  "afternoon",
  "ahi",
  "ai",
  "algo",
  "anything",
  "asi",
  "ate",
  "bem",
  "boa",
  "boas",
  "bom",
  "buen",
  "buena",
  "buenas",
  "bueno",
  "buenos",
  "bye",
  "chao",
  "chau",
  "coisa",
  "cualquier",
  "cya",
  "dale",
  "de",
  "dia",
  "dias",
  "entendido",
  "es",
  "esta",
  "evening",
  "excelente",
  "fine",
  "genial",
  "good",
  "goodbye",
  "gracias",
  "great",
  "hello",
  "hey",
  "hi",
  "hola",
  "is",
  "it",
  "later",
  "listo",
  "logo",
  "mais",
  "manana",
  "manhã",
  "morning",
  "muchas",
  "muito",
  "muito",
  "need",
  "no",
  "noite",
  "night",
  "noches",
  "obrigada",
  "obrigado",
  "ok",
  "okay",
  "ola",
  "perfect",
  "perfecto",
  "perfeito",
  "see",
  "si",
  "sim",
  "tarde",
  "tardes",
  "thank",
  "thanks",
  "then",
  "todo",
  "tudo",
  "you",
  "welcome",
]);

const GREETING_PATTERNS = [
  /\b(hola|buenas|buenos dias|buen dia|buenas tardes|buenas noches)\b/,
  /\b(hi|hello|hey|good morning|good afternoon|good evening|good night)\b/,
  /\b(ola|olá|bom dia|boa tarde|boa noite)\b/,
];

const THANKS_PATTERNS = [
  /\b(gracias|muchas gracias)\b/,
  /\b(thanks|thank you)\b/,
  /\b(obrigado|obrigada|muito obrigado|muito obrigada)\b/,
];

const ACK_PATTERNS = [
  /\b(ok|okay|dale|listo|perfecto|entendido|genial|excelente|asi esta bien|esta bien|todo bien)\b/,
  /\b(perfect|great|fine|sounds good|got it|all good)\b/,
  /\b(perfeito|tudo bem|esta bem|está bem|entendi|beleza)\b/,
];

const GOODBYE_PATTERNS = [
  /\b(chau|chao|hasta luego|nos vemos)\b/,
  /\b(bye|goodbye|see you|see you later)\b/,
  /\b(tchau|ate logo|até logo)\b/,
];

export function classifyConversationalOnly(message: unknown): ConversationalClassification | null {
  const original = String(message || "").trim();
  const normalized = normalizeText(original);
  if (!normalized) return null;
  if (!containsSocialSignal(normalized)) return null;
  if (!onlySocialTokens(normalized)) return null;

  const language = detectConversationalLanguage(normalized);
  if (matchesAny(normalized, GOODBYE_PATTERNS)) {
    return { kind: "goodbye", language, response: goodbyeResponse(language) };
  }
  if (matchesAny(normalized, THANKS_PATTERNS)) {
    return { kind: "thanks", language, response: thanksResponse(language) };
  }
  if (matchesAny(normalized, ACK_PATTERNS) && !matchesAny(normalized, GREETING_PATTERNS)) {
    return { kind: "acknowledgement", language, response: acknowledgementResponse(language) };
  }
  if (matchesAny(normalized, GREETING_PATTERNS)) {
    return { kind: "greeting", language, response: greetingResponse(language, normalized) };
  }

  return { kind: "small_talk", language, response: acknowledgementResponse(language) };
}

export function shouldBypassModelForConversational(classification: ConversationalClassification | null) {
  return classification?.kind === "greeting";
}

function containsSocialSignal(normalized: string) {
  return matchesAny(normalized, [
    ...GREETING_PATTERNS,
    ...THANKS_PATTERNS,
    ...ACK_PATTERNS,
    ...GOODBYE_PATTERNS,
  ]);
}

function onlySocialTokens(normalized: string) {
  const tokens = normalized.split(/\s+/).filter(Boolean);
  return tokens.length > 0 && tokens.every((token) => SOCIAL_TOKENS.has(token));
}

function detectConversationalLanguage(normalized: string): "es" | "en" | "pt" {
  if (/\b(ola|olá|bom dia|boa tarde|boa noite|obrigad[ao]|perfeito|tudo bem|entendi|beleza)\b/.test(normalized)) {
    return "pt";
  }
  if (/\b(hi|hello|hey|good morning|good afternoon|good evening|good night|thanks|thank you|bye|goodbye|perfect|great|got it)\b/.test(normalized)) {
    return "en";
  }
  return "es";
}

function greetingResponse(language: "es" | "en" | "pt", normalized: string) {
  if (language === "en") {
    if (/\bgood afternoon\b/.test(normalized)) return "Good afternoon. How can I help?";
    if (/\bgood evening\b|\bgood night\b/.test(normalized)) return "Good evening. How can I help?";
    if (/\bgood morning\b/.test(normalized)) return "Good morning. How can I help?";
    return "Hi, how can I help?";
  }
  if (language === "pt") {
    if (/\bboa tarde\b/.test(normalized)) return "Boa tarde. Como posso ajudar?";
    if (/\bboa noite\b/.test(normalized)) return "Boa noite. Como posso ajudar?";
    if (/\bbom dia\b/.test(normalized)) return "Bom dia. Como posso ajudar?";
    return "Olá, como posso ajudar?";
  }
  if (/\bbuenas tardes\b/.test(normalized)) return "Hola, buenas tardes. ¿En qué puedo ayudarte?";
  if (/\bbuenas noches\b/.test(normalized)) return "Buenas noches. ¿En qué puedo ayudarte?";
  if (/\bbuenos dias\b|\bbuen dia\b/.test(normalized)) return "Buen día. ¿En qué puedo ayudarte?";
  return "Hola, ¿en qué puedo ayudarte?";
}

function thanksResponse(language: "es" | "en" | "pt") {
  if (language === "en") return "You're welcome. Let me know if you need anything else.";
  if (language === "pt") return "De nada. Se precisar de algo mais, é só me avisar.";
  return "De nada. Avisame si necesitás algo más.";
}

function acknowledgementResponse(language: "es" | "en" | "pt") {
  if (language === "en") return "Perfect, let me know if you need anything else.";
  if (language === "pt") return "Perfeito, qualquer coisa é só me escrever.";
  return "Perfecto, cualquier cosa escribime.";
}

function goodbyeResponse(language: "es" | "en" | "pt") {
  if (language === "en") return "Goodbye. Let me know if you need anything else.";
  if (language === "pt") return "Até logo. Se precisar de algo mais, é só me avisar.";
  return "Hasta luego. Cualquier cosa escribime.";
}

function matchesAny(value: string, patterns: RegExp[]) {
  return patterns.some((pattern) => pattern.test(value));
}

function normalizeText(value: string) {
  return value
    .normalize("NFD")
    .replace(/\p{Diacritic}/gu, "")
    .toLowerCase()
    .replace(/[^\p{Letter}\p{Number}\s]/gu, " ")
    .replace(/\s+/g, " ")
    .trim();
}
