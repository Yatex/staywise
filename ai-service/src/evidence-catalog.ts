export type ToolResultRow = {
  toolName: string;
  result: unknown;
};

export type EvidenceCatalogEntry = {
  evidence_id: string;
  raw_id: string;
  field: string | null;
  value: unknown;
  tool_name: string;
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
  const normalized = raw.toLowerCase().replace(/[^a-z0-9]/g, "");
  if (["propertycheckintime", "propertyfactcheckintime"].includes(normalized)) {
    return "property.check_in_time";
  }

  return raw;
}

export function shouldRetryGroundedDecision(decision: any, evidenceCatalog: EvidenceCatalogEntry[]) {
  if (evidenceCatalog.length === 0) return false;

  const outcome = decision?.outcome || decision?.decision;
  const unknownIntent = asArray(decision?.detected_intents).some((intent: any) => intent?.type === "unknown");
  const citedEvidence = asArray(decision?.evidence_ids).concat(asArray(decision?.used_source_ids)).filter(Boolean);

  return ["escalate", "propose_action"].includes(outcome) && unknownIntent && citedEvidence.length === 0;
}

function evidenceEntries(value: unknown, toolName: string): EvidenceCatalogEntry[] {
  if (Array.isArray(value)) return value.flatMap((item) => evidenceEntries(item, toolName));
  if (!value || typeof value !== "object") return [];

  const item = value as Record<string, unknown>;
  const rawId = item.evidence_id || item.source_id || item.id;
  const directEntry: EvidenceCatalogEntry[] = rawId && item.value !== undefined
    ? [{
        evidence_id: canonicalEvidenceId(rawId),
        raw_id: String(rawId),
        field: String(item.field || item.label || "") || null,
        value: item.value,
        tool_name: toolName,
      }]
    : [];
  const nestedEntries = Object.values(item).flatMap((nested) => evidenceEntries(nested, toolName));

  return directEntry.concat(nestedEntries);
}

function asArray(value: unknown): unknown[] {
  if (Array.isArray(value)) return value;
  return value == null ? [] : [value];
}
