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

type RepairDecisionDiagnostic = {
  value: boolean;
  reason: string;
};

type CandidateAudit = {
  evidence_id: string;
  field: string | null;
  label: string | null;
  value: unknown;
  content: string | null;
  excerpt: string | null;
  score: number;
  matched_terms: string[];
  source_type: string | null;
  reason_included_or_excluded: string;
};

type SufficientCandidateAudit = {
  evidence_id: string;
  sufficiency_score: number;
  reason: string;
};

type GroundedDecisionBuilderAudit = {
  should_repair_decision: RepairDecisionDiagnostic;
  evidence_catalog_size: number;
  ranked_candidates: CandidateAudit[];
  sufficient_candidates: SufficientCandidateAudit[];
  grounded_decision_result: {
    override_created: boolean;
    override_type: string | null;
    reason_if_null: string | null;
  };
  final_decision_source: {
    model: boolean;
    retry_model: boolean;
    grounded_override: boolean;
    fallback: boolean;
  };
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
  const repairDiagnostic = shouldRepairDecisionDiagnostic(decision);
  const candidateAudit = rankedCandidateAudit(payload?.guest_message || "", evidenceCatalog);
  const baseAudit = {
    should_repair_decision: repairDiagnostic,
    evidence_catalog_size: evidenceCatalog.length,
    ranked_candidates: candidateAudit,
  };

  if (!repairDiagnostic.value) {
    return withGroundedAudit(
      { decision, override: null },
      buildAudit(baseAudit, [], null, "decision_does_not_need_repair"),
    );
  }

  const candidates = rankedCandidates(payload?.guest_message || "", evidenceCatalog);
  if (candidates.length === 0) {
    return withGroundedAudit(
      { decision, override: null },
      buildAudit(baseAudit, sufficientCandidateAudit(candidates, []), null, "no_ranked_candidates"),
    );
  }

  const sufficient = sufficientCandidates(candidates);
  const sufficiencyAudit = sufficientCandidateAudit(candidates, sufficient);
  if (sufficient.length > 0) {
    if (sufficient.some((candidate) => approvalRequired(candidate.evidence))) {
      return withGroundedAudit(
        approvalDecision(decision, payload, sufficient, previousOutcome),
        buildAudit(baseAudit, sufficiencyAudit, "approval_required", null),
      );
    }

    return withGroundedAudit(
      replyDecision(decision, payload, sufficient, previousOutcome),
      buildAudit(baseAudit, sufficiencyAudit, "sufficient_evidence", null),
    );
  }

  return withGroundedAudit(
    clarificationDecision(decision, payload, candidates.slice(0, 3), previousOutcome),
    buildAudit(baseAudit, sufficiencyAudit, "partial_evidence", null),
  );
}

function shouldRepairDecision(decision: any) {
  return shouldRepairDecisionDiagnostic(decision).value;
}

function shouldRepairDecisionDiagnostic(decision: any): RepairDecisionDiagnostic {
  const outcome = String(decision?.outcome || decision?.decision || "");
  const hasCitations = arrayOf(decision?.evidence_ids).concat(arrayOf(decision?.used_source_ids)).length > 0;
  const unknownIntent = arrayOf(decision?.detected_intents).some((intent: any) => intent?.type === "unknown");
  const fallback = arrayOf(decision?.safety_flags).some((flag) => String(flag) === "fallback");

  if (["escalate", "propose_action"].includes(outcome)) {
    return { value: true, reason: `outcome_${outcome}_requires_grounding_check` };
  }
  if (unknownIntent) return { value: true, reason: "unknown_intent_requires_grounding_check" };
  if (fallback) return { value: true, reason: "fallback_flag_requires_grounding_check" };
  if (outcome === "reply" && !hasCitations) return { value: true, reason: "reply_without_evidence_ids" };

  return { value: false, reason: "decision_already_grounded_or_not_repairable" };
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
  return scoreEvidenceWithDebug(queryTokens, evidence).score;
}

function scoreEvidenceWithDebug(queryTokens: string[], evidence: EvidenceCatalogEntry) {
  const evidenceTokens = tokens([
    evidence.field,
    evidence.label,
    evidence.category,
    evidence.source_type,
    evidence.text,
  ].filter(Boolean).join(" "));
  if (evidenceTokens.length === 0) {
    return {
      score: 0,
      matched_terms: [] as string[],
      reason: "no_evidence_tokens",
    };
  }

  const matchedTerms: string[] = [];
  const score = queryTokens.reduce((sum, queryToken) => {
    if (evidenceTokens.includes(queryToken)) {
      matchedTerms.push(queryToken);
      return sum + 3;
    }
    const fuzzyMatch = queryToken.length >= 5 && evidenceTokens.find((evidenceToken) => editDistanceAtMostOne(queryToken, evidenceToken));
    if (fuzzyMatch) {
      matchedTerms.push(`${queryToken}~${fuzzyMatch}`);
      return sum + 2;
    }

    return sum;
  }, 0);

  return {
    score,
    matched_terms: unique(matchedTerms),
    reason: score > 0 ? "matched_query_terms" : "no_query_terms_matched_evidence",
  };
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

function rankedCandidateAudit(message: string, evidenceCatalog: EvidenceCatalogEntry[]): CandidateAudit[] {
  const queryTokens = tokens(message);
  return evidenceCatalog
    .map((evidence) => {
      const debug = queryTokens.length === 0
        ? { score: 0, matched_terms: [] as string[], reason: "no_query_tokens" }
        : scoreEvidenceWithDebug(queryTokens, evidence);

      return {
        evidence_id: evidence.evidence_id,
        field: evidence.field || null,
        label: evidence.label || null,
        value: evidence.value ?? null,
        content: evidence.text || null,
        excerpt: String(evidence.metadata?.excerpt || evidence.text || "").slice(0, 500) || null,
        score: debug.score,
        matched_terms: debug.matched_terms,
        source_type: evidence.source_type || null,
        reason_included_or_excluded: debug.score > 0 ? "included_score_positive" : `excluded_${debug.reason}`,
      };
    })
    .sort((left, right) => right.score - left.score);
}

function sufficientCandidateAudit(candidates: Candidate[], sufficient: Candidate[]): SufficientCandidateAudit[] {
  if (candidates.length === 0) return [];

  const sufficientIds = new Set(sufficient.map((candidate) => candidate.evidence.evidence_id));
  const topScore = candidates[0]?.score || 0;
  const topCandidates = candidates.filter((candidate) => candidate.score === topScore);
  const distinctLabels = unique(topCandidates.map((candidate) => humanLabel(candidate.evidence)));

  return topCandidates.map((candidate) => {
    let reason = "top_score_meets_threshold_single_label";
    if (!sufficientIds.has(candidate.evidence.evidence_id)) {
      if (topScore < 3) {
        reason = "score_below_sufficiency_threshold";
      } else if (distinctLabels.length > 1) {
        reason = "ambiguous_top_candidates";
      } else {
        reason = "not_selected_as_sufficient";
      }
    }

    return {
      evidence_id: candidate.evidence.evidence_id,
      sufficiency_score: candidate.score,
      reason,
    };
  });
}

function buildAudit(
  base: Pick<GroundedDecisionBuilderAudit, "should_repair_decision" | "evidence_catalog_size" | "ranked_candidates">,
  sufficientCandidates: SufficientCandidateAudit[],
  overrideType: string | null,
  reasonIfNull: string | null,
): GroundedDecisionBuilderAudit {
  const overrideCreated = overrideType != null;
  return {
    ...base,
    sufficient_candidates: sufficientCandidates,
    grounded_decision_result: {
      override_created: overrideCreated,
      override_type: overrideType,
      reason_if_null: reasonIfNull,
    },
    final_decision_source: {
      model: !overrideCreated,
      retry_model: false,
      grounded_override: overrideCreated,
      fallback: false,
    },
  };
}

function withGroundedAudit(build: GroundedDecisionBuild, audit: GroundedDecisionBuilderAudit): GroundedDecisionBuild {
  return {
    ...build,
    decision: {
      ...build.decision,
      audit: {
        ...(build.decision?.audit || {}),
        grounded_decision_builder: audit,
      },
    },
  };
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
