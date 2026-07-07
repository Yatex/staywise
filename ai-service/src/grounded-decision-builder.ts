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

type DecisionStrategy =
  | "direct_reply"
  | "reply_with_inference"
  | "clarify_before_escalate"
  | "escalation_last_resort";

type Candidate = {
  evidence: EvidenceCatalogEntry;
  score: number;
  matched_terms: string[];
  semantic_matches: string[];
  strategy: "direct" | "inference";
  inferred_intent: string;
  inference_reason: string | null;
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
  semantic_matches: string[];
  source_type: string | null;
  reason_included_or_excluded: string;
  inferred_intent: string | null;
  inference_reason: string | null;
};

type SufficientCandidateAudit = {
  evidence_id: string;
  sufficiency_score: number;
  reason: string;
};

type GroundedDecisionBuilderAudit = {
  called: boolean;
  should_repair_decision: RepairDecisionDiagnostic;
  evidence_catalog_size: number;
  includes_property_check_in_time: boolean;
  ranked_candidates: CandidateAudit[];
  sufficient_candidates: SufficientCandidateAudit[];
  grounded_decision_result: {
    override_created: boolean;
    override_type: string | null;
    reason_if_null: string | null;
    reason_if_no_override: string | null;
  };
  final_decision_source: {
    model: boolean;
    retry_model: boolean;
    grounded_override: boolean;
    fallback: boolean;
  };
  final_decision_strategy: DecisionStrategy;
  inferred_intent: string | null;
  inference_reason: string | null;
  decision_scores: DecisionScores;
  score_thresholds: DecisionThresholds;
  clarification_attempts: {
    intent: string;
    count: number;
    max: number;
  };
  clarification_question: string | null;
  ambiguity_candidates: string[];
  evidence_candidates_ranked: CandidateAudit[];
};

type DecisionScores = {
  answer_confidence: number;
  evidence_relevance_score: number;
  safety_score: number;
};

type DecisionThresholds = {
  high_score_threshold: number;
  medium_score_threshold: number;
  safety_score_threshold: number;
  max_clarification_attempts: number;
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

const HIGH_SCORE_THRESHOLD = 75;
const MEDIUM_SCORE_THRESHOLD = 40;
const SAFETY_SCORE_THRESHOLD = 75;
const DEFAULT_MAX_CLARIFICATION_ATTEMPTS = 2;

const INTENT_CATEGORIES = [
  {
    category: "arrival",
    intent: "check_in_time",
    fields: ["check_in_time", "checkin", "check_in", "arrival", "arrival_time", "ingreso", "entrada"],
    terms: ["entrada", "entrar", "ingresar", "ingreso", "llegada", "llegar", "depto", "departamento", "arrival", "arrive", "checkin"],
  },
  {
    category: "departure",
    intent: "check_out_time",
    fields: ["check_out_time", "checkout", "check_out", "departure", "departure_time", "salida"],
    terms: ["salida", "salir", "irme", "dejar", "checkout", "departure", "depart", "leave"],
  },
  {
    category: "parking",
    intent: "parking",
    fields: ["parking", "parking_instructions", "garage", "cochera", "estacionamiento"],
    terms: ["auto", "coche", "carro", "estacionar", "parking", "garage", "cochera"],
  },
  {
    category: "address",
    intent: "address",
    fields: ["address", "location", "direccion", "ubicacion"],
    terms: ["direccion", "ubicacion", "location", "address", "maps", "mapa"],
  },
  {
    category: "rules",
    intent: "rules",
    fields: ["rules", "house_rules", "policy", "reglas"],
    terms: ["reglas", "permitido", "prohibido", "fiestas", "rules", "allowed", "forbidden"],
  },
  {
    category: "wifi",
    intent: "wifi",
    fields: ["wifi", "wifi_name", "wifi_password", "internet"],
    terms: ["wifi", "internet", "contrasena", "clave", "password"],
  },
] as const;

export function buildGroundedDecision(
  decision: any,
  payload: any,
  evidenceCatalog: EvidenceCatalogEntry[],
): GroundedDecisionBuild {
  const previousOutcome = String(decision?.outcome || decision?.decision || "") || null;
  const guestMessage = payload?.guest_message || "";
  const thresholds = decisionThresholds(payload);
  const repairDiagnostic = shouldRepairDecisionDiagnostic(decision);
  const candidateAudit = rankedCandidateAudit(guestMessage, evidenceCatalog);
  const clarificationIntent = inferredClarificationIntent(guestMessage);
  const attempts = clarificationAttempts(payload, clarificationIntent);
  const baseAudit = {
    called: true,
    should_repair_decision: repairDiagnostic,
    evidence_catalog_size: evidenceCatalog.length,
    includes_property_check_in_time: includesEvidenceId(evidenceCatalog, "property.check_in_time"),
    ranked_candidates: candidateAudit,
    clarification_attempts: {
      intent: clarificationIntent,
      count: attempts,
      max: thresholds.max_clarification_attempts,
    },
    score_thresholds: thresholds,
  };

  if (!repairDiagnostic.value) {
    return withGroundedAudit(
      { decision, override: null },
      buildAudit(baseAudit, [], null, "decision_does_not_need_repair", {
        strategy: strategyForExistingDecision(decision),
        scores: scoresForExistingDecision(decision, candidateAudit),
      }),
    );
  }

  const candidates = rankedCandidates(guestMessage, evidenceCatalog);
  if (candidates.length === 0) {
    const clarification = attempts < thresholds.max_clarification_attempts
      ? clarificationWithoutEvidence(guestMessage, decision, payload, previousOutcome)
      : null;
    if (clarification) {
      return withGroundedAudit(
        clarification,
        buildAudit(baseAudit, [], "partial_evidence", null, {
          strategy: "clarify_before_escalate",
          inferredIntent: clarification.decision.detected_intents?.[0]?.type || null,
          clarificationQuestion: clarification.decision.message_body || null,
          ambiguityCandidates: [],
          scores: scoresForClarification([], thresholds, { safetyScore: 50 }),
        }),
      );
    }

    if (attempts >= thresholds.max_clarification_attempts && clarificationCategory(guestMessage)) {
      return withGroundedAudit(
        { decision, override: null },
        buildAudit(baseAudit, [], null, "clarification_attempts_exhausted", {
          strategy: "escalation_last_resort",
          inferredIntent: clarificationIntent,
          scores: scoresForEscalation([], thresholds),
        }),
      );
    }

    return withGroundedAudit(
      { decision, override: null },
      buildAudit(baseAudit, sufficientCandidateAudit(candidates, []), null, "no_ranked_candidates", {
        strategy: "escalation_last_resort",
        scores: scoresForEscalation([], thresholds),
      }),
    );
  }

  const sufficient = sufficientCandidates(candidates, thresholds);
  const sufficiencyAudit = sufficientCandidateAudit(candidates, sufficient);
  if (sufficient.length > 0) {
    if (sufficient.some((candidate) => approvalRequired(candidate.evidence))) {
      return withGroundedAudit(
        approvalDecision(decision, payload, sufficient, previousOutcome),
        buildAudit(baseAudit, sufficiencyAudit, "approval_required", null, {
          strategy: "escalation_last_resort",
          inferredIntent: sufficient[0]?.inferred_intent || null,
          inferenceReason: sufficient[0]?.inference_reason || null,
          scores: scoresForCandidates(sufficient, thresholds, { safetyScore: 35 }),
        }),
      );
    }

    const strategy = sufficient.some((candidate) => candidate.strategy === "inference") ? "reply_with_inference" : "direct_reply";
    const replyScores = scoresForCandidates(sufficient, thresholds, { safetyScore: 95 });
    if (replyScores.safety_score < thresholds.safety_score_threshold && attempts < thresholds.max_clarification_attempts) {
      const clarification = clarificationDecision(decision, payload, candidates.slice(0, 3), previousOutcome);
      return withGroundedAudit(
        clarification,
        buildAudit(baseAudit, sufficiencyAudit, "partial_evidence", null, {
          strategy: "clarify_before_escalate",
          inferredIntent: sufficient[0]?.inferred_intent || "ambiguous_request",
          clarificationQuestion: clarification.decision.message_body || null,
          ambiguityCandidates: unique(candidates.slice(0, 3).map((candidate) => candidate.inferred_intent)),
          scores: replyScores,
        }),
      );
    }

    return withGroundedAudit(
      replyDecision(decision, payload, sufficient, previousOutcome, strategy),
      buildAudit(baseAudit, sufficiencyAudit, "sufficient_evidence", null, {
        strategy,
        inferredIntent: sufficient[0]?.inferred_intent || null,
        inferenceReason: sufficient[0]?.inference_reason || null,
        scores: replyScores,
      }),
    );
  }

  if (attempts < thresholds.max_clarification_attempts) {
    const clarification = clarificationDecision(decision, payload, candidates.slice(0, 3), previousOutcome);
    return withGroundedAudit(
      clarification,
      buildAudit(baseAudit, sufficiencyAudit, "partial_evidence", null, {
        strategy: "clarify_before_escalate",
        inferredIntent: "ambiguous_request",
        clarificationQuestion: clarification.decision.message_body || null,
        ambiguityCandidates: unique(candidates.slice(0, 3).map((candidate) => candidate.inferred_intent)),
        scores: scoresForClarification(candidates, thresholds),
      }),
    );
  }

  return withGroundedAudit(
    { decision, override: null },
    buildAudit(baseAudit, sufficiencyAudit, null, "clarification_attempts_exhausted", {
      strategy: "escalation_last_resort",
      inferredIntent: "ambiguous_request",
      ambiguityCandidates: unique(candidates.slice(0, 3).map((candidate) => candidate.inferred_intent)),
      scores: scoresForEscalation(candidates, thresholds),
    }),
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
  const queryCategories = queryIntentCategories(message);
  if (queryTokens.length === 0 && queryCategories.length === 0) return [];

  return evidenceCatalog
    .map((evidence) => {
      const debug = scoreEvidenceWithDebug(queryTokens, evidence, queryCategories);
      return {
        evidence,
        score: debug.score,
        matched_terms: debug.matched_terms,
        semantic_matches: debug.semantic_matches,
        strategy: debug.strategy,
        inferred_intent: debug.inferred_intent,
        inference_reason: debug.inference_reason,
      };
    })
    .filter((candidate) => candidate.score > 0)
    .sort((left, right) => right.score - left.score);
}

function sufficientCandidates(candidates: Candidate[], thresholds: DecisionThresholds) {
  const topScore = candidates[0]?.score || 0;
  if (relevanceScore(candidates) < thresholds.high_score_threshold) return [];

  const topCandidates = candidates.filter((candidate) => candidate.score === topScore);
  const distinctLabels = unique(topCandidates.map((candidate) => humanLabel(candidate.evidence)));
  if (distinctLabels.length > 1) return [];

  return topCandidates;
}

function scoreEvidence(queryTokens: string[], evidence: EvidenceCatalogEntry) {
  return scoreEvidenceWithDebug(queryTokens, evidence, []).score;
}

function scoreEvidenceWithDebug(queryTokens: string[], evidence: EvidenceCatalogEntry, queryCategories: string[]) {
  const evidenceTokens = tokens([
    evidence.field,
    evidence.label,
    evidence.category,
    evidence.source_type,
    evidence.text,
  ].filter(Boolean).join(" "));
  const evidenceCategories = evidenceIntentCategories(evidence);
  if (evidenceTokens.length === 0 && evidenceCategories.length === 0) {
    return {
      score: 0,
      matched_terms: [] as string[],
      semantic_matches: [] as string[],
      reason: "no_evidence_tokens",
      strategy: "direct" as const,
      inferred_intent: inferredIntent(evidence),
      inference_reason: null,
    };
  }

  const matchedTerms: string[] = [];
  let score = queryTokens.reduce((sum, queryToken) => {
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
  const semanticMatches = queryCategories.filter((category) => evidenceCategories.includes(category));
  if (semanticMatches.length > 0) score += 4 * semanticMatches.length;
  if (score > 0 && ["faq", "knowledge_block"].includes(String(evidence.source_type))) score += 2;
  const strategy: "direct" | "inference" = matchedTerms.length > 0 ? "direct" : "inference";
  const semanticIntent = semanticMatches.length > 0 ? intentForCategory(semanticMatches[0]) : inferredIntent(evidence);

  return {
    score,
    matched_terms: unique(matchedTerms),
    semantic_matches: unique(semanticMatches),
    reason: score > 0 ? "matched_query_terms_or_semantic_category" : "no_query_terms_matched_evidence",
    strategy,
    inferred_intent: semanticIntent,
    inference_reason: semanticMatches.length > 0 ? `query_category:${semanticMatches.join(",")}` : null,
  };
}

function replyDecision(
  decision: any,
  payload: any,
  candidates: Candidate[],
  previousOutcome: string | null,
  strategy: DecisionStrategy = "direct_reply",
): GroundedDecisionBuild {
  const primary = candidates[0].evidence;
  const evidenceIds = unique(candidates.map((candidate) => candidate.evidence.evidence_id));
  const language = normalizedLanguage(decision?.language || payload?.guest_language_fallback || "en");
  const messageBody = strategy === "reply_with_inference"
    ? inferredResponseFromEvidence(primary, language, candidates[0].inferred_intent)
    : responseFromEvidence(primary, language);

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
        type: candidates[0].inferred_intent || inferredIntent(primary),
        status: strategy === "reply_with_inference" ? "answered_with_inference" : "answered",
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
  const intentType = isAmbiguousTime(candidates.map((candidate) => candidate.inferred_intent)) ? "ambiguous_time" : "ambiguous_request";

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
        type: intentType,
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

function inferredResponseFromEvidence(evidence: EvidenceCatalogEntry, language: string, intent: string) {
  const value = String(evidence.value || "").trim();
  if (intent === "check_in_time") {
    if (language === "es") return `Si te referís al horario de ingreso/check-in, podés entrar a partir de las ${value}.`;
    if (language === "fr") return `Si vous parlez de l'arrivée/check-in, vous pouvez entrer à partir de ${value}.`;
    return `If you mean arrival/check-in, you can enter from ${value}.`;
  }
  if (intent === "check_out_time") {
    if (language === "es") return `Si te referís al horario de salida/check-out, el checkout es a las ${value}.`;
    if (language === "fr") return `Si vous parlez du départ/check-out, le check-out est à ${value}.`;
    return `If you mean departure/check-out, checkout is at ${value}.`;
  }
  if (intent === "parking") {
    if (language === "es") return `Si te referís a dónde dejar el auto, la información disponible es: ${value}.`;
    if (language === "fr") return `Si vous parlez du stationnement, voici l'information disponible : ${value}.`;
    return `If you mean parking, the available information is: ${value}.`;
  }
  if (intent === "address") {
    if (language === "es") return `Si te referís a la ubicación o dirección, es: ${value}.`;
    if (language === "fr") return `Si vous parlez de l'adresse ou de l'emplacement, c'est : ${value}.`;
    return `If you mean the address or location, it is: ${value}.`;
  }

  return responseFromEvidence(evidence, language);
}

function approvalMessage(evidence: EvidenceCatalogEntry, language: string) {
  const label = humanLabel(evidence);
  if (language === "es") return `${label} requiere aprobación del anfitrión. Voy a pedir esa aprobación sin confirmarla todavía.`;
  if (language === "fr") return `${label} nécessite l'approbation de l'hôte. Je vais demander cette approbation sans encore la confirmer.`;
  return `${label} requires host approval. I will ask for that approval without confirming it yet.`;
}

function clarificationMessage(evidence: EvidenceCatalogEntry[], language: string) {
  const intents = unique(evidence.map(inferredIntent));
  if (intents.includes("check_in_time") && intents.includes("check_out_time")) {
    if (language === "es") return "¿Te referís al horario de entrada/check-in o al horario de salida/check-out?";
    if (language === "fr") return "Vous parlez de l'heure d'arrivée/check-in ou de l'heure de départ/check-out ?";
    return "Do you mean the arrival/check-in time or the departure/check-out time?";
  }

  const labels = unique(evidence.map(humanLabel)).slice(0, 3);
  if (language === "es") return `Encontré información relacionada con ${labels.join(", ")}. ¿Me aclarás a cuál te referís?`;
  if (language === "fr") return `J'ai trouvé des informations liées à ${labels.join(", ")}. Pouvez-vous préciser laquelle vous voulez dire ?`;
  return `I found information related to ${labels.join(", ")}. Can you clarify which one you mean?`;
}

function isAmbiguousTime(intents: string[]) {
  return intents.includes("check_in_time") && intents.includes("check_out_time");
}

function clarificationWithoutEvidence(message: string, decision: any, payload: any, previousOutcome: string | null): GroundedDecisionBuild | null {
  const category = clarificationCategory(message);
  if (!category) return null;

  const language = normalizedLanguage(decision?.language || payload?.guest_language_fallback || "en");
  const messageBody = clarificationWithoutEvidenceMessage(category, language);
  return {
    override: {
      applied: true,
      reason: "partial_evidence",
      evidence_ids: [],
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
      intent_summary: "No direct evidence matched yet, but the guest can clarify before escalation.",
      detected_intents: [{
        type: category === "issue" ? "ambiguous_issue" : "ambiguous_request",
        status: "needs_clarification",
      }],
      evidence_ids: [],
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
      confidence: Math.max(Number(decision?.confidence || 0), 0.65),
    },
  };
}

function clarificationWithoutEvidenceMessage(category: string, language: string) {
  if (category === "issue") {
    if (language === "es") return "¿Qué es lo que no está funcionando: WiFi, puerta, agua, luz u otra cosa?";
    if (language === "fr") return "Qu'est-ce qui ne fonctionne pas exactement : le WiFi, la porte, l'eau, l'électricité ou autre chose ?";
    return "What exactly is not working: WiFi, the door, water, electricity, or something else?";
  }

  if (language === "es") return "¿Me aclarás un poco más a qué te referís?";
  if (language === "fr") return "Pouvez-vous préciser un peu ce que vous voulez dire ?";
  return "Can you clarify a bit what you mean?";
}

function summaryForHost(payload: any, evidence: EvidenceCatalogEntry) {
  return `El huésped pidió algo relacionado con ${humanLabel(evidence)} y la política encontrada requiere aprobación. Pregunta original: ${payload?.guest_message || ""}`;
}

function approvalRequired(evidence: EvidenceCatalogEntry) {
  const text = [evidence.value, evidence.text].join(" ");
  return APPROVAL_PATTERNS.some((pattern) => pattern.test(text));
}

function inferredIntent(evidence: EvidenceCatalogEntry) {
  return canonicalIntentName(snakeCase(evidence.field || evidence.label || evidence.category || evidence.source_type || "grounded_answer"));
}

function canonicalIntentName(intent: string) {
  if (intent === "checkin_time" || intent === "check_in" || intent === "checkin") return "check_in_time";
  if (intent === "checkout_time" || intent === "check_out" || intent === "checkout") return "check_out_time";
  return intent;
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

function looseTokens(value: string) {
  return normalizeText(value)
    .split(/\s+/)
    .filter((token) => token.length >= 2);
}

function queryIntentCategories(message: string) {
  const text = normalizeText(message);
  const rawTokens = looseTokens(message);
  const categories: string[] = INTENT_CATEGORIES
    .filter((definition) => intersects(rawTokens, definition.terms))
    .map((definition) => definition.category);

  const hasTimeLanguage = intersects(rawTokens, ["hora", "horario", "cuando", "time", "heure", "quel", "quelle"]);
  const genericArrivalOrDeparture = intersects(rawTokens, ["ir", "voy", "go", "aller"]);
  if (hasTimeLanguage && genericArrivalOrDeparture) categories.push("arrival", "departure");
  if (text.includes("no anda") || text.includes("no funciona") || text.includes("not working") || text.includes("doesnt work")) {
    categories.push("issue");
  }

  return unique(categories);
}

function evidenceIntentCategories(evidence: EvidenceCatalogEntry) {
  const haystack = looseTokens([
    evidence.evidence_id,
    evidence.field,
    evidence.label,
    evidence.category,
    evidence.source_type,
    evidence.text,
  ].filter(Boolean).join(" "));

  return unique(INTENT_CATEGORIES
    .filter((definition) => intersects(haystack, definition.fields) || intersects(haystack, definition.terms))
    .map((definition) => definition.category));
}

function intentForCategory(category: string) {
  return INTENT_CATEGORIES.find((definition) => definition.category === category)?.intent || `${category}_request`;
}

function clarificationCategory(message: string) {
  return queryIntentCategories(message).includes("issue") ? "issue" : null;
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
  const queryCategories = queryIntentCategories(message);
  return evidenceCatalog
    .map((evidence) => {
      const debug = queryTokens.length === 0 && queryCategories.length === 0
        ? {
            score: 0,
            matched_terms: [] as string[],
            semantic_matches: [] as string[],
            reason: "no_query_tokens",
            inferred_intent: inferredIntent(evidence),
            inference_reason: null,
          }
        : scoreEvidenceWithDebug(queryTokens, evidence, queryCategories);

      return {
        evidence_id: evidence.evidence_id,
        field: evidence.field || null,
        label: evidence.label || null,
        value: evidence.value ?? null,
        content: evidence.text || null,
        excerpt: String(evidence.metadata?.excerpt || evidence.text || "").slice(0, 500) || null,
        score: debug.score,
        matched_terms: debug.matched_terms,
        semantic_matches: debug.semantic_matches,
        source_type: evidence.source_type || null,
        reason_included_or_excluded: debug.score > 0 ? "included_score_positive" : `excluded_${debug.reason}`,
        inferred_intent: debug.inferred_intent,
        inference_reason: debug.inference_reason,
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
  base: Pick<GroundedDecisionBuilderAudit, "called" | "should_repair_decision" | "evidence_catalog_size" | "includes_property_check_in_time" | "ranked_candidates" | "clarification_attempts" | "score_thresholds">,
  sufficientCandidates: SufficientCandidateAudit[],
  overrideType: string | null,
  reasonIfNull: string | null,
  options: {
    strategy?: DecisionStrategy;
    inferredIntent?: string | null;
    inferenceReason?: string | null;
    scores?: DecisionScores;
    clarificationQuestion?: string | null;
    ambiguityCandidates?: string[];
  } = {},
): GroundedDecisionBuilderAudit {
  const overrideCreated = overrideType != null;
  return {
    ...base,
    sufficient_candidates: sufficientCandidates,
    grounded_decision_result: {
      override_created: overrideCreated,
      override_type: overrideType,
      reason_if_null: reasonIfNull,
      reason_if_no_override: reasonIfNull,
    },
    final_decision_source: {
      model: !overrideCreated,
      retry_model: false,
      grounded_override: overrideCreated,
      fallback: false,
    },
    final_decision_strategy: options.strategy || (overrideCreated ? "direct_reply" : "escalation_last_resort"),
    inferred_intent: options.inferredIntent || null,
    inference_reason: options.inferenceReason || null,
    decision_scores: options.scores || scoresForEscalation([], base.score_thresholds),
    score_thresholds: base.score_thresholds,
    clarification_attempts: base.clarification_attempts,
    clarification_question: options.clarificationQuestion || null,
    ambiguity_candidates: options.ambiguityCandidates || [],
    evidence_candidates_ranked: base.ranked_candidates,
  };
}

function strategyForExistingDecision(decision: any): DecisionStrategy {
  const outcome = String(decision?.outcome || decision?.decision || "");
  if (outcome === "ask_clarifying_question") return "clarify_before_escalate";
  if (outcome === "escalate" || outcome === "propose_action") return "escalation_last_resort";
  return "direct_reply";
}

function scoresForCandidates(candidates: Candidate[], thresholds: DecisionThresholds, options: { safetyScore?: number } = {}): DecisionScores {
  const evidenceRelevanceScore = relevanceScore(candidates);
  const safetyScore = options.safetyScore ?? 95;
  return {
    answer_confidence: clampScore(Math.round((evidenceRelevanceScore * 0.75) + (safetyScore * 0.25))),
    evidence_relevance_score: evidenceRelevanceScore,
    safety_score: clampScore(safetyScore),
  };
}

function scoresForClarification(candidates: Candidate[], thresholds: DecisionThresholds, options: { safetyScore?: number } = {}): DecisionScores {
  const evidenceRelevanceScore = relevanceScore(candidates);
  return {
    answer_confidence: clampScore(Math.max(thresholds.medium_score_threshold, Math.min(thresholds.high_score_threshold - 5, evidenceRelevanceScore))),
    evidence_relevance_score: evidenceRelevanceScore,
    safety_score: clampScore(options.safetyScore ?? 65),
  };
}

function scoresForEscalation(candidates: Candidate[] = [], thresholds: DecisionThresholds = defaultDecisionThresholds()): DecisionScores {
  return {
    answer_confidence: clampScore(candidates.length > 0 ? Math.min(thresholds.medium_score_threshold - 5, relevanceScore(candidates)) : 15),
    evidence_relevance_score: relevanceScore(candidates),
    safety_score: 35,
  };
}

function scoresForExistingDecision(decision: any, candidates: CandidateAudit[]): DecisionScores {
  const relevance = clampScore(Math.round(Math.min(100, Number(candidates[0]?.score || 0) * 20)));
  const outcome = String(decision?.outcome || decision?.decision || "");
  if (outcome === "reply") {
    return {
      answer_confidence: clampScore(Math.round(Number(decision?.confidence || 0.8) * 100)),
      evidence_relevance_score: relevance,
      safety_score: 90,
    };
  }
  if (outcome === "ask_clarifying_question") {
    return {
      answer_confidence: Math.max(MEDIUM_SCORE_THRESHOLD, Math.min(70, relevance || MEDIUM_SCORE_THRESHOLD)),
      evidence_relevance_score: relevance,
      safety_score: 65,
    };
  }
  return scoresForEscalation();
}

function relevanceScore(candidates: Candidate[]) {
  const topScore = candidates[0]?.score || 0;
  return clampScore(Math.round(Math.min(100, topScore * 20)));
}

function clampScore(score: number) {
  return Math.max(0, Math.min(100, Number.isFinite(score) ? score : 0));
}

function clarificationAttempts(payload: any, intent: string) {
  const configured = payload?.clarification_attempts;
  if (typeof configured === "number") return configured;
  if (configured && typeof configured === "object") {
    const byIntent = configured[intent] ?? configured[String(intent)] ?? configured.total;
    if (Number.isFinite(Number(byIntent))) return Number(byIntent);
  }

  return inferredClarificationAttempts(payload?.conversation_history, intent);
}

function decisionThresholds(payload: any): DecisionThresholds {
  const configured = payload?.decision_settings || payload?.base_context?.decision_settings || {};
  const envMax = Number(process.env.AYLA_MAX_CLARIFICATION_ATTEMPTS || process.env.MAX_CLARIFICATION_ATTEMPTS || DEFAULT_MAX_CLARIFICATION_ATTEMPTS);
  const medium = boundedScore(configured.medium_score_threshold, MEDIUM_SCORE_THRESHOLD);
  const high = Math.max(medium, boundedScore(configured.high_score_threshold, HIGH_SCORE_THRESHOLD));

  return {
    high_score_threshold: high,
    medium_score_threshold: medium,
    safety_score_threshold: boundedScore(configured.safety_score_threshold, SAFETY_SCORE_THRESHOLD),
    max_clarification_attempts: boundedInteger(configured.max_clarification_attempts, Number.isFinite(envMax) ? envMax : DEFAULT_MAX_CLARIFICATION_ATTEMPTS, 0, 10),
  };
}

function defaultDecisionThresholds(): DecisionThresholds {
  return {
    high_score_threshold: HIGH_SCORE_THRESHOLD,
    medium_score_threshold: MEDIUM_SCORE_THRESHOLD,
    safety_score_threshold: SAFETY_SCORE_THRESHOLD,
    max_clarification_attempts: DEFAULT_MAX_CLARIFICATION_ATTEMPTS,
  };
}

function boundedScore(value: unknown, fallback: number) {
  return boundedInteger(value, fallback, 0, 100);
}

function boundedInteger(value: unknown, fallback: number, min: number, max: number) {
  const number = Number(value);
  if (!Number.isFinite(number)) return fallback;
  return Math.max(min, Math.min(max, Math.round(number)));
}

function inferredClarificationAttempts(history: any, intent: string) {
  if (!Array.isArray(history)) return 0;

  return history.filter((message: any) => {
    const sender = String(message?.sender || "");
    if (!["ai", "system"].includes(sender)) return false;

    const body = String(message?.body || "");
    if (!body.includes("?") && !body.includes("¿")) return false;

    const categories = queryIntentCategories(body);
    const genericClarification = /\b(aclar|precisar|specify|clarify|exactamente|exactly)\b/i.test(body);
    const issueClarification = /\b(wifi|puerta|agua|luz|door|water|electricity)\b/i.test(body);
    if (intent === "ambiguous_issue") return categories.includes("issue") || genericClarification || issueClarification;
    if (intent === "ambiguous_time") return categories.includes("arrival") || categories.includes("departure") || genericClarification;

    return genericClarification || categories.length > 0;
  }).length;
}

function inferredClarificationIntent(message: string) {
  const categories = queryIntentCategories(message);
  if (categories.includes("issue")) return "ambiguous_issue";
  if (categories.includes("arrival") && categories.includes("departure")) return "ambiguous_time";
  return categories[0] ? `${categories[0]}_request` : "ambiguous_request";
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

function includesEvidenceId(evidenceCatalog: EvidenceCatalogEntry[], evidenceId: string) {
  return evidenceCatalog.some((entry) => entry.evidence_id === evidenceId);
}

function unique(values: string[]) {
  return Array.from(new Set(values.filter(Boolean)));
}

function intersects(left: readonly string[], right: readonly string[]) {
  return left.some((item) => right.includes(item));
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
