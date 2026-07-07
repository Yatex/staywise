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
    .replace(/\s*\n\s*/g, "\n")
    .trim();

  return cleaned.length > 0 ? cleaned : null;
}
