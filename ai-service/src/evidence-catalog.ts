export type ToolResultRow = {
  toolName: string;
  result: unknown;
};

export type EvidenceCatalogEntry = {
  evidence_id: string;
  raw_id: string;
  field: string | null;
  label: string | null;
  source_type: string | null;
  category: string | null;
  value: unknown;
  text: string;
  sensitivity: string | null;
  authorization_required: boolean;
  authorized: boolean | null;
  metadata: Record<string, unknown>;
  tool_name: string;
};

type EvidenceContext = {
  authorized?: boolean | null;
};

export function buildEvidenceCatalog(toolResults: ToolResultRow[]): EvidenceCatalogEntry[] {
  const entries = toolResults.flatMap((toolResult) => evidenceEntries(toolResult.result, toolResult.toolName));
  const unique = new Map<string, EvidenceCatalogEntry>();

  for (const entry of entries) {
    const key = `${entry.evidence_id}:${JSON.stringify(entry.value)}`;
    if (!unique.has(key)) unique.set(key, entry);
  }

  return Array.from(unique.values());
}

export function canonicalEvidenceId(value: unknown) {
  const raw = String(value || "");
  const normalized = raw.trim();

  const propertyFact = normalized.match(/^property_fact[:._-](.+)$/i);
  if (propertyFact) return `property.${propertyFact[1]}`;

  const reservationFact = normalized.match(/^reservation_fact[:._-](.+)$/i);
  if (reservationFact) return `reservation.${reservationFact[1]}`;

  const policy = normalized.match(/^policy[:._-](.+)$/i);
  if (policy) return `policy.${policy[1]}`;

  const faq = normalized.match(/^faq[:._-](\d+)$/i);
  if (faq) return `faq.${faq[1]}`;

  const guide = normalized.match(/^(guide|knowledge_block)[:._-](\d+)$/i);
  if (guide) return `guide.${guide[2]}`;

  const recommendation = normalized.match(/^recommendation[:._-](\d+)$/i);
  if (recommendation) return `recommendation.${recommendation[1]}`;

  const propertySource = normalized.match(/^property_(.+)$/i);
  if (propertySource) return `property.${propertySource[1]}`;

  const sensitiveSource = normalized.match(/^sensitive_(.+)$/i);
  if (sensitiveSource) return `property.${sensitiveSource[1]}`;

  const reservationSource = normalized.match(/^reservation_(.+)$/i);
  if (reservationSource) return `reservation.${reservationSource[1]}`;

  return raw;
}

export function shouldRetryGroundedDecision(decision: any, evidenceCatalog: EvidenceCatalogEntry[]) {
  if (evidenceCatalog.length === 0) return false;

  const outcome = decision?.outcome || decision?.decision;
  const unknownIntent = asArray(decision?.detected_intents).some((intent: any) => intent?.type === "unknown");
  const citedEvidence = asArray(decision?.evidence_ids).concat(asArray(decision?.used_source_ids)).filter(Boolean);

  return ["escalate", "propose_action"].includes(outcome) && unknownIntent && citedEvidence.length === 0;
}

function evidenceEntries(value: unknown, toolName: string, context: EvidenceContext = {}): EvidenceCatalogEntry[] {
  if (Array.isArray(value)) return value.flatMap((item) => evidenceEntries(item, toolName, context));
  if (!value || typeof value !== "object") return [];

  const item = value as Record<string, unknown>;
  const itemContext = {
    ...context,
    authorized: booleanOrNull(item.authorized) ?? context.authorized ?? null,
  };
  const rawId = item.evidence_id || item.source_id || item.id;
  const entryValue = item.value ?? item.content ?? item.excerpt;
  const directEntry: EvidenceCatalogEntry[] = rawId && entryValue !== undefined
    ? [catalogEntry(item, rawId, entryValue, toolName, itemContext)]
    : [];
  const nestedEntries = Object.values(item).flatMap((nested) => evidenceEntries(nested, toolName, itemContext));

  return directEntry.concat(nestedEntries);
}

function catalogEntry(
  item: Record<string, unknown>,
  rawId: unknown,
  value: unknown,
  toolName: string,
  context: EvidenceContext,
): EvidenceCatalogEntry {
  const field = stringOrNull(item.field || item.label || item.title);
  const label = stringOrNull(item.label || item.title || item.field);
  const sourceType = stringOrNull(item.source_type || item.type);
  const category = stringOrNull(item.category);
  const sensitivity = stringOrNull(item.sensitivity || item.sensitive_level) || inferredSensitivity(toolName, rawId, field, label, sourceType);
  const authorizationRequired = booleanOrNull(item.authorization_required ?? item.requires_authorization) ??
    (sensitivity !== null || toolName === "sensitive_access_info");
  const authorized = booleanOrNull(item.authorized) ?? context.authorized ?? (authorizationRequired ? null : true);
  const metadata = Object.fromEntries(
    Object.entries(item).filter(([key]) => ![
      "evidence_id",
      "source_id",
      "id",
      "field",
      "label",
      "title",
      "source_type",
      "type",
      "category",
      "value",
      "content",
      "excerpt",
      "sensitivity",
      "sensitive_level",
      "authorization_required",
      "requires_authorization",
      "authorized",
    ].includes(key)),
  );

  return {
    evidence_id: canonicalEvidenceId(rawId),
    raw_id: String(rawId),
    field,
    label,
    source_type: sourceType,
    category,
    value,
    text: [label, field, category, sourceType, value].filter(Boolean).join(" "),
    sensitivity,
    authorization_required: authorizationRequired,
    authorized,
    metadata,
    tool_name: toolName,
  };
}

function inferredSensitivity(toolName: string, rawId: unknown, field: string | null, label: string | null, sourceType: string | null) {
  const haystack = [toolName, rawId, field, label, sourceType].filter(Boolean).join(" ").toLowerCase();
  if (toolName === "sensitive_access_info" || /\b(sensitive|password|wifi_password|access_code|lockbox|key|code)\b/.test(haystack)) {
    return "sensitive";
  }
  return null;
}

function booleanOrNull(value: unknown) {
  if (value === true || value === "true") return true;
  if (value === false || value === "false") return false;
  return null;
}

function stringOrNull(value: unknown) {
  const stringValue = String(value || "").trim();
  return stringValue.length > 0 ? stringValue : null;
}

function asArray(value: unknown): unknown[] {
  if (Array.isArray(value)) return value;
  return value == null ? [] : [value];
}
