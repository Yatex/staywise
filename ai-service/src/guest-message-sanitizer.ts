const METADATA_LABELS = [
  "source",
  "sources",
  "source_id",
  "source_ids",
  "evidence",
  "evidence_id",
  "evidence_ids",
  "used_source_id",
  "used_source_ids",
  "matched_source",
  "matched_sources",
  "fuente",
  "fuentes",
  "origen",
  "orígenes",
  "origine",
  "origines",
  "référence",
  "références",
  "reference",
  "references",
  "источник",
  "источники",
  "tool",
  "tools",
  "audit",
  "trace",
];

const INTERNAL_DOT_PREFIXES = [
  "account",
  "alert",
  "conversation",
  "faq",
  "guest",
  "guide",
  "knowledge_block",
  "message",
  "policy",
  "property",
  "recommendation",
  "reservation",
  "source",
  "tool",
];

const INTERNAL_COLON_PREFIXES = [
  "account_fact",
  "alert",
  "conversation",
  "evidence",
  "faq",
  "guest_context",
  "guest_fact",
  "guide",
  "knowledge_block",
  "policy",
  "property_brain",
  "property_fact",
  "recommendation",
  "reservation_fact",
  "source",
  "stay_fact",
  "tool",
];

const TOOL_NAMES = [
  "create_escalation_draft",
  "escalation_draft",
  "guest_context",
  "property_brain",
  "sensitive_access_info",
  "stay_facts",
];

const metadataLabelPattern = METADATA_LABELS.join("|");
const dotPrefixPattern = INTERNAL_DOT_PREFIXES.join("|");
const colonPrefixPattern = INTERNAL_COLON_PREFIXES.join("|");
const toolNamePattern = TOOL_NAMES.join("|");
const internalReferencePattern = [
  `(?:${dotPrefixPattern})\\.[a-z0-9_./-]+`,
  `(?:${colonPrefixPattern}):[a-z0-9_.:/-]+`,
  "[a-z0-9_.:/-]+",
].join("|");

const SOURCE_CLAIM_PATTERNS = [
  "\\bseg[uú]n\\s+(?:la\\s+)?informaci[oó]n\\s+disponible\\s*[,.:;-]?\\s*",
  "\\bseg[uú]n\\s+mis\\s+registros\\s*[,.:;-]?\\s*",
  "\\bde\\s+acuerdo\\s+con\\s+(?:la\\s+)?base\\s+de\\s+datos\\s*[,.:;-]?\\s*",
  "\\bde\\s+acuerdo\\s+con\\s+(?:la\\s+)?informaci[oó]n\\s+disponible\\s*[,.:;-]?\\s*",
  "\\baccording\\s+to\\s+(?:the\\s+)?available\\s+information\\s*[,.:;-]?\\s*",
  "\\baccording\\s+to\\s+my\\s+records\\s*[,.:;-]?\\s*",
  "\\baccording\\s+to\\s+(?:the\\s+)?database\\s*[,.:;-]?\\s*",
  "\\bbased\\s+on\\s+(?:the\\s+)?available\\s+information\\s*[,.:;-]?\\s*",
  "\\bselon\\s+les\\s+informations\\s+disponibles\\s*[,.:;-]?\\s*",
  "\\bd['’]apr[eè]s\\s+les\\s+informations\\s+disponibles\\s*[,.:;-]?\\s*",
  "(?:^|\\s)согласно\\s+доступной\\s+информации\\s*[,.:;-]?\\s*",
  "(?:^|\\s)по\\s+моим\\s+данным\\s*[,.:;-]?\\s*",
  "(?:^|\\s)в\\s+базе\\s+данных\\s+указано\\s*,?\\s*(?:что\\s+)?",
];

export function sanitizeGuestVisibleText(value: unknown) {
  if (value == null) return null;

  let text = String(value);

  text = text.replace(
    new RegExp(`\\s*[\\(\\[]\\s*(?:${metadataLabelPattern})\\s*[:：][^\\)\\]]*[\\)\\]]`, "gi"),
    "",
  );
  text = text.replace(
    new RegExp(`\\s*[\\(\\[]\\s*(?:${metadataLabelPattern})\\s*[\\)\\]]`, "gi"),
    "",
  );
  text = text.replace(
    new RegExp(`\\b(?:${metadataLabelPattern})\\s*[:：]\\s*(?:${internalReferencePattern})(?:\\s*,\\s*(?:${internalReferencePattern}))*`, "gi"),
    "",
  );
  text = text.replace(
    new RegExp(`\\b(?:${dotPrefixPattern})\\.[a-z0-9_./-]+\\b`, "gi"),
    "",
  );
  text = text.replace(
    new RegExp(`\\b(?:${colonPrefixPattern}):[a-z0-9_.:/-]+\\b`, "gi"),
    "",
  );
  text = text.replace(
    new RegExp(`\\b(?:${toolNamePattern})\\b`, "gi"),
    "",
  );
  for (const pattern of SOURCE_CLAIM_PATTERNS) {
    text = text.replace(new RegExp(pattern, "giu"), "");
  }
  text = removeClarificationEcho(text);

  return cleanGuestText(text);
}

export function sanitizeDecisionGuestText<T extends Record<string, unknown>>(decision: T): T {
  const sanitized: Record<string, unknown> = { ...decision };

  if ("message_body" in sanitized) {
    sanitized.message_body = sanitizeGuestVisibleText(sanitized.message_body);
  }

  if ("response_text" in sanitized) {
    sanitized.response_text = sanitizeGuestVisibleText(sanitized.response_text);
  }

  if ("safe_fallback_response" in sanitized) {
    sanitized.safe_fallback_response = sanitizeGuestVisibleText(sanitized.safe_fallback_response);
  }

  return sanitized as T;
}

function cleanGuestText(text: string) {
  const cleaned = text
    .replace(/\(\s*\)/g, "")
    .replace(/\[\s*\]/g, "")
    .replace(/\s+([,.;:!?])/g, "$1")
    .replace(/([([{])\s+/g, "$1")
    .replace(/\s+([)\]}])/g, "$1")
    .replace(/[ \t]{2,}/g, " ")
    .replace(/\s+([.])/g, "$1")
    .replace(/\s*\n\s*/g, "\n")
    .trim();

  return cleaned.length > 0 ? capitalizeSentenceStart(cleaned) : null;
}

function removeClarificationEcho(text: string) {
  let cleaned = text;

  cleaned = cleaned.replace(
    /^\s*(perfecto|correcto|ok|okay|entendido|listo|genial|excelente)(?:\s*\([^)]*\))?\s*[:.,-]\s*/i,
    "",
  );

  cleaned = cleaned.replace(
    /^\s*(te\s+refer[ií]s|te\s+refieres|habl[aá]s|quieres\s+decir|quer[eé]s\s+decir)\s+[^.?!:]+[.?!:]\s*/i,
    "",
  );

  cleaned = cleaned.replace(
    /^\s*(si\s+te\s+refer[ií]s|si\s+te\s+refieres|si\s+vous\s+parlez|if\s+you\s+mean)\s+[^.?!:]+[.?!:]\s*/i,
    "",
  );

  return cleaned;
}

function capitalizeSentenceStart(text: string) {
  return text.replace(/^(\p{Ll})/u, (match) => match.toLocaleUpperCase());
}
