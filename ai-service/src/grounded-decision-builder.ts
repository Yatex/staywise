import type { EvidenceCatalogEntry } from "./evidence-catalog.js";

export type GroundedDecisionBuild = {
  decision: any;
  override: GroundedDecisionOverride | null;
};

export type GroundedDecisionOverride = {
  applied: boolean;
  reason: "sufficient_evidence" | "approval_required" | "partial_evidence";
  evidence_ids: string[];
  sufficiency: "sufficient" | "partial";
  previous_outcome: string | null;
};

type Candidate = {
  evidence: EvidenceCatalogEntry;
  score: number;
};

const STOPWORDS = new Set([
  "a",
  "al",
  "algo",
  "and",
  "are",
  "can",
  "como",
  "con",
  "could",
  "de",
  "del",
  "do",
  "does",
  "donde",
  "el",
  "en",
  "es",
  "est",
  "esta",
  "este",
  "for",
  "how",
  "i",
  "is",
  "it",
  "la",
  "las",
  "le",
  "lo",
  "los",
  "me",
  "mi",
  "my",
  "of",
  "on",
  "para",
  "please",
  "por",
  "q",
  "que",
  "quelle",
  "se",
  "si",
  "su",
  "te",
  "the",
  "to",
  "tu",
  "un",
  "una",
  "what",
  "when",
  "where",
  "with",
  "you",
]);

const APPROVAL_PATTERNS = [
  /approval[_\s-]?required/i,
  /requires?\s+(host|owner|human)?\s*approval/i,
  /host\s+confirmation/i,
  /owner\s+confirmation/i,
  /confirmaci[oó]n\s+del\s+anfitri[oó]n/i,
  /aprobaci[oó]n/i,
  /consult(ar|arlo|arlo)?\s+con\s+el\s+anfitri[oó]n/i,
];

export function buildGroundedDecision(
  decision: any,
  payload: any,
  evidenceCatalog: EvidenceCatalogEntry[],
): GroundedDecisionBuild {
  const previousOutcome = String(decision?.outcome || decision?.decision || "") || null;
  if (!shouldRepairDecision(decision)) return { decision, override: null };

  const candidates = rankedCandidates(payload?.guest_message || "", evidenceCatalog);
  if (candidates.length === 0) return { decision, override: null };

  const sufficient = sufficientCandidates(candidates);
  if (sufficient.length > 0) {
    if (sufficient.some((candidate) => approvalRequired(candidate.evidence))) {
      return approvalDecision(decision, payload, sufficient, previousOutcome);
    }

    return replyDecision(decision, payload, sufficient, previousOutcome);
  }

  return clarificationDecision(decision, payload, candidates.slice(0, 3), previousOutcome);
}

function shouldRepairDecision(decision: any) {
  const outcome = String(decision?.outcome || decision?.decision || "");
  const hasCitations = arrayOf(decision?.evidence_ids).concat(arrayOf(decision?.used_source_ids)).length > 0;
  const unknownIntent = arrayOf(decision?.detected_intents).some((intent: any) => intent?.type === "unknown");
  const fallback = arrayOf(decision?.safety_flags).some((flag) => String(flag) === "fallback");

  return (
    ["escalate", "propose_action"].includes(outcome) ||
    unknownIntent ||
    fallback ||
    (outcome === "reply" && !hasCitations)
  );
}

function rankedCandidates(message: string, evidenceCatalog: EvidenceCatalogEntry[]) {
  const queryTokens = tokens(message);
  if (queryTokens.length === 0) return [];

  return evidenceCatalog
    .map((evidence) => ({ evidence, score: scoreEvidence(queryTokens, evidence) }))
    .filter((candidate) => candidate.score > 0)
    .sort((left, right) => right.score - left.score);
}

function sufficientCandidates(candidates: Candidate[]) {
  const topScore = candidates[0]?.score || 0;
  if (topScore < 3) return [];

  const topCandidates = candidates.filter((candidate) => candidate.score === topScore);
  const distinctLabels = unique(topCandidates.map((candidate) => humanLabel(candidate.evidence)));
  if (distinctLabels.length > 1) return [];

  return topCandidates;
}

function scoreEvidence(queryTokens: string[], evidence: EvidenceCatalogEntry) {
  const evidenceTokens = tokens([
    evidence.field,
    evidence.label,
    evidence.category,
    evidence.source_type,
    evidence.text,
  ].filter(Boolean).join(" "));
  if (evidenceTokens.length === 0) return 0;

  return queryTokens.reduce((score, queryToken) => {
    if (evidenceTokens.includes(queryToken)) return score + 3;
    if (queryToken.length >= 5 && evidenceTokens.some((evidenceToken) => editDistanceAtMostOne(queryToken, evidenceToken))) {
      return score + 2;
    }

    return score;
  }, 0);
}

function replyDecision(
  decision: any,
  payload: any,
  candidates: Candidate[],
  previousOutcome: string | null,
): GroundedDecisionBuild {
  const primary = candidates[0].evidence;
  const evidenceIds = unique(candidates.map((candidate) => candidate.evidence.evidence_id));
  const language = normalizedLanguage(decision?.language || payload?.guest_language_fallback || "en");
  const messageBody = responseFromEvidence(primary, language);

  return {
    override: {
      applied: true,
      reason: "sufficient_evidence",
      evidence_ids: evidenceIds,
      sufficiency: "sufficient",
      previous_outcome: previousOutcome,
    },
    decision: {
      ...decision,
      outcome: "reply",
      decision: "reply",
      language,
      message_body: messageBody,
      response_text: messageBody,
      intent_summary: `Answered from ${primary.source_type || "evidence"} evidence.`,
      detected_intents: [{
        type: inferredIntent(primary),
        status: "answered",
      }],
      evidence_ids: evidenceIds,
      used_source_ids: [],
      required_capabilities: [],
      proposed_action: null,
      escalation: {
        required: false,
        reason_code: null,
        summary_for_host: null,
      },
      escalation_required: false,
      escalation_reason: null,
      missing_information: [],
      safety_flags: removeFallbackFlag(decision?.safety_flags),
      confidence: Math.max(Number(decision?.confidence || 0), 0.9),
    },
  };
}

function approvalDecision(
  decision: any,
  payload: any,
  candidates: Candidate[],
  previousOutcome: string | null,
): GroundedDecisionBuild {
  const primary = candidates.find((candidate) => approvalRequired(candidate.evidence))?.evidence || candidates[0].evidence;
  const evidenceIds = unique(candidates.map((candidate) => candidate.evidence.evidence_id));
  const language = normalizedLanguage(decision?.language || payload?.guest_language_fallback || "en");
  const messageBody = approvalMessage(primary, language);

  return {
    override: {
      applied: true,
      reason: "approval_required",
      evidence_ids: evidenceIds,
      sufficiency: "sufficient",
      previous_outcome: previousOutcome,
    },
    decision: {
      ...decision,
      outcome: "propose_action",
      decision: "propose_action",
      language,
      message_body: messageBody,
      response_text: messageBody,
      intent_summary: `Policy evidence requires human approval for ${primary.field || primary.label || "this request"}.`,
      detected_intents: [{
        type: inferredIntent(primary),
        status: "requires_host_approval",
      }],
      evidence_ids: evidenceIds,
      used_source_ids: [],
      required_capabilities: ["owner_approval"],
      proposed_action: {
        type: "human_handoff",
        payload: {
          evidence_ids: evidenceIds,
          policy: primary.field || primary.label || primary.evidence_id,
        },
      },
      escalation: {
        required: true,
        reason_code: "owner_approval_required",
        summary_for_host: summaryForHost(payload, primary),
      },
      escalation_required: true,
      escalation_reason: "owner_approval_required",
      missing_information: [],
      safety_flags: removeFallbackFlag(decision?.safety_flags),
      confidence: Math.max(Number(decision?.confidence || 0), 0.85),
    },
  };
}

function clarificationDecision(
  decision: any,
  payload: any,
  candidates: Candidate[],
  previousOutcome: string | null,
): GroundedDecisionBuild {
  const evidenceIds = unique(candidates.map((candidate) => candidate.evidence.evidence_id));
  const language = normalizedLanguage(decision?.language || payload?.guest_language_fallback || "en");
  const messageBody = clarificationMessage(candidates.map((candidate) => candidate.evidence), language);

  return {
    override: {
      applied: true,
      reason: "partial_evidence",
      evidence_ids: evidenceIds,
      sufficiency: "partial",
      previous_outcome: previousOutcome,
    },
    decision: {
      ...decision,
      outcome: "ask_clarifying_question",
      decision: "ask_clarifying_question",
      language,
      message_body: messageBody,
      response_text: messageBody,
      intent_summary: "Partial evidence found, but the guest request needs clarification.",
      detected_intents: [{
        type: "ambiguous_request",
        status: "needs_clarification",
      }],
      evidence_ids: evidenceIds,
      used_source_ids: [],
      required_capabilities: [],
      proposed_action: null,
      escalation: {
        required: false,
        reason_code: null,
        summary_for_host: null,
      },
      escalation_required: false,
      escalation_reason: null,
      missing_information: ["clarification_from_guest"],
      safety_flags: removeFallbackFlag(decision?.safety_flags),
      confidence: Math.max(Number(decision?.confidence || 0), 0.7),
    },
  };
}

function responseFromEvidence(evidence: EvidenceCatalogEntry, language: string) {
  const value = String(evidence.value || "").trim();
  const label = humanLabel(evidence);

  if (evidence.source_type === "recommendation") {
    const details = [
      label,
      value,
      evidence.metadata.address,
      evidence.metadata.distance_or_walking_time,
      evidence.metadata.google_maps_url,
    ].filter(Boolean).join(" - ");
    return details.endsWith(".") ? details : `${details}.`;
  }

  if (["faq", "knowledge_block"].includes(String(evidence.source_type))) {
    return value.endsWith(".") ? value : `${value}.`;
  }

  if (language === "es") return `${label}: ${value}.`;
  if (language === "fr") return `${label} : ${value}.`;
  return `${label}: ${value}.`;
}

function approvalMessage(evidence: EvidenceCatalogEntry, language: string) {
  const label = humanLabel(evidence);
  if (language === "es") return `${label} requiere aprobación del anfitrión. Voy a pedir esa aprobación sin confirmarla todavía.`;
  if (language === "fr") return `${label} nécessite l'approbation de l'hôte. Je vais demander cette approbation sans encore la confirmer.`;
  return `${label} requires host approval. I will ask for that approval without confirming it yet.`;
}

function clarificationMessage(evidence: EvidenceCatalogEntry[], language: string) {
  const labels = unique(evidence.map(humanLabel)).slice(0, 3);
  if (language === "es") return `Encontré información relacionada con ${labels.join(", ")}. ¿Me aclarás a cuál te referís?`;
  if (language === "fr") return `J'ai trouvé des informations liées à ${labels.join(", ")}. Pouvez-vous préciser laquelle vous voulez dire ?`;
  return `I found information related to ${labels.join(", ")}. Can you clarify which one you mean?`;
}

function summaryForHost(payload: any, evidence: EvidenceCatalogEntry) {
  return `El huésped pidió algo relacionado con ${humanLabel(evidence)} y la política encontrada requiere aprobación. Pregunta original: ${payload?.guest_message || ""}`;
}

function approvalRequired(evidence: EvidenceCatalogEntry) {
  const text = [evidence.value, evidence.text].join(" ");
  return APPROVAL_PATTERNS.some((pattern) => pattern.test(text));
}

function inferredIntent(evidence: EvidenceCatalogEntry) {
  return snakeCase(evidence.field || evidence.label || evidence.category || evidence.source_type || "grounded_answer");
}

function humanLabel(evidence: EvidenceCatalogEntry) {
  return String(evidence.label || evidence.field || evidence.category || evidence.source_type || "Información")
    .replace(/[_-]+/g, " ")
    .trim();
}

function tokens(value: string) {
  const baseTokens = normalizeText(value)
    .split(/\s+/)
    .filter((token) => token.length >= 3)
    .filter((token) => !STOPWORDS.has(token));

  return unique(expandTokens(baseTokens));
}

function normalizeText(value: string) {
  return value
    .toLowerCase()
    .normalize("NFD")
    .replace(/\p{Diacritic}/gu, "")
    .replace(/[_-]+/g, " ")
    .replace(/\bcheck\s+in\b/g, "checkin")
    .replace(/\bcheck\s+out\b/g, "checkout")
    .replace(/\bq\b/g, " que ")
    .replace(/[^\p{Letter}\p{Number}\s]+/gu, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function expandTokens(tokens: string[]) {
  const expanded = tokens.slice();
  if (tokens.some((token) => ["visita", "visitas", "invitado", "invitados", "invitar", "gente", "visitor", "visitors", "guests", "friends"].includes(token))) {
    expanded.push("visitors", "permission");
  }
  if (tokens.some((token) => ["cafe", "coffee", "restaurant", "restaurante", "comer", "cenar", "recomendar", "recommendation"].includes(token))) {
    expanded.push("recommendation");
  }
  return expanded;
}

function snakeCase(value: string) {
  return normalizeText(value).replace(/\s+/g, "_") || "grounded_answer";
}

function normalizedLanguage(language?: string) {
  return String(language || "en").split(/[-_]/)[0] || "en";
}

function removeFallbackFlag(flags: unknown) {
  return arrayOf(flags).filter((flag) => String(flag) !== "fallback");
}

function unique(values: string[]) {
  return Array.from(new Set(values.filter(Boolean)));
}

function arrayOf(value: unknown): any[] {
  if (Array.isArray(value)) return value;
  return value == null ? [] : [value];
}

function editDistanceAtMostOne(left: string, right: string) {
  if (left === right) return true;
  if (Math.abs(left.length - right.length) > 1) return false;

  let i = 0;
  let j = 0;
  let edits = 0;

  while (i < left.length && j < right.length) {
    if (left[i] === right[j]) {
      i += 1;
      j += 1;
    } else if (edits === 0) {
      edits += 1;
      if (left.length > right.length) {
        i += 1;
      } else if (right.length > left.length) {
        j += 1;
      } else {
        i += 1;
        j += 1;
      }
    } else {
      return false;
    }
  }

  return edits + (left.length - i) + (right.length - j) <= 1;
}
