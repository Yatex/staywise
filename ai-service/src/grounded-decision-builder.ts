import type { EvidenceCatalogEntry } from "./evidence-catalog.js";
import { classifyConversationalOnly } from "./conversational-classifier.js";

export type GroundedDecisionBuild = {
  decision: any;
  override: GroundedDecisionOverride | null;
};

export type GroundedDecisionOverride = {
  applied: boolean;
  reason: "sufficient_evidence" | "approval_required" | "partial_evidence" | "missing_sensitive_information";
  evidence_ids: string[];
  sufficiency: "sufficient" | "partial" | "insufficient";
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

type EvidenceGroup = {
  intent: string;
  candidates: Candidate[];
  top_score: number;
  source_priority: number;
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
  "hay",
  "tenes",
  "tenés",
  "tienes",
  "alguna",
  "algun",
  "algún",
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

const SENSITIVE_TYPE_DEFINITIONS = [
  {
    type: "property.wifi_password",
    terms: ["wifi", "wi-fi", "internet", "red", "network"],
    secretTerms: ["clave", "contrasena", "contraseña", "password"],
  },
  {
    type: "property.safe_code",
    terms: ["caja", "fuerte", "safe", "safety", "seguridad"],
    secretTerms: ["codigo", "code", "clave", "contrasena", "contraseña", "password"],
  },
  {
    type: "property.lockbox_code",
    terms: ["lockbox", "caja", "llaves", "llave", "keybox", "keys"],
    secretTerms: ["codigo", "code", "clave", "pin"],
  },
  {
    type: "property.door_code",
    terms: ["puerta", "door", "cerradura", "entrada", "acceso"],
    secretTerms: ["codigo", "code", "clave", "pin"],
  },
  {
    type: "property.gate_code",
    terms: ["porton", "portón", "gate", "garage", "cochera"],
    secretTerms: ["codigo", "code", "clave", "pin"],
  },
  {
    type: "property.alarm_code",
    terms: ["alarma", "alarm"],
    secretTerms: ["codigo", "code", "clave", "pin"],
  },
  {
    type: "property.building_access_code",
    terms: ["edificio", "building", "entrada", "acceso", "hall"],
    secretTerms: ["codigo", "code", "clave", "pin"],
  },
  {
    type: "property.key_location",
    terms: ["llave", "llaves", "key", "keys", "ubicacion", "donde"],
    secretTerms: ["ubicacion", "location", "donde", "where"],
  },
  {
    type: "property.device_password",
    terms: ["dispositivo", "device", "netflix", "tv", "alarma", "router"],
    secretTerms: ["clave", "contrasena", "contraseña", "password"],
  },
] as const;

const RECOMMENDATION_CATEGORY_ALIASES: Record<string, string[]> = {
  restaurant: ["restaurant", "restaurants", "restaurante", "restaurantes", "comer", "cenar", "almorzar", "food", "dining", "comida"],
  cafe: ["cafe", "cafes", "coffee", "cafeteria", "cafetería", "desayuno"],
  supermarket: ["supermarket", "supermercado", "supermercados", "grocery", "groceries", "market", "mercado", "almacen", "almacén"],
  pharmacy: ["pharmacy", "farmacia", "farmacias", "drugstore"],
  transport: ["transport", "transporte", "taxi", "bus", "uber", "colectivo", "metro"],
  attraction: ["attraction", "atraccion", "atracción", "atracciones", "actividad", "actividades", "visitar", "paseo", "turismo"],
};

const GENERIC_RECOMMENDATION_TERMS = new Set([
  "recomendacion", "recomendaciones", "recomendar", "recomiendes", "recomendas", "recomendame", "recommendation", "recommend",
  "lugar", "lugares", "place", "places", "nearby", "cerca", "opcion", "opciones", "cualquiera", "whatever", "anything",
  ...Object.values(RECOMMENDATION_CATEGORY_ALIASES).flat(),
]);

const INTENT_CATEGORIES = [
  {
    category: "access",
    intent: "access",
    fields: ["access", "access_instructions", "access_code", "entrance", "entry", "entry_code", "lockbox", "key", "keys", "codigo", "llave"],
    terms: ["acceso", "entrada", "entrar", "entro", "ingresar", "ingreso", "edificio", "depto", "departamento", "porton", "puerta", "codigo", "código", "llave", "key", "keys", "code", "lockbox", "door"],
  },
  {
    category: "arrival",
    intent: "check_in_time",
    fields: ["check_in_time", "checkin", "check_in", "arrival", "arrival_time", "ingreso", "entrada"],
    terms: ["llegada", "llegar", "arrival", "arrive", "checkin"],
  },
  {
    category: "departure",
    intent: "check_out_time",
    fields: ["check_out_time", "checkout_instructions", "checkout", "check_out", "departure", "departure_time", "salida"],
    terms: ["salida", "salir", "irme", "dejar", "checkout", "departure", "depart", "leave"],
  },
  {
    category: "parking",
    intent: "parking",
    fields: ["parking", "parking_instructions", "garage", "cochera", "estacionamiento"],
    terms: ["auto", "coche", "carro", "estacionar", "estaciono", "parking", "garage", "cochera"],
  },
  {
    category: "address",
    intent: "address",
    fields: ["address", "location", "direccion", "ubicacion"],
    terms: ["direccion", "ubicacion", "location", "address", "maps", "mapa"],
  },
  {
    category: "recommendation",
    intent: "recommendation",
    fields: ["recommendation", "recommendations", "place", "name", "address", "restaurant", "food", "cafe", "grocery", "supermarket", "pharmacy", "transport", "attraction"],
    terms: ["recomendar", "recomendacion", "recomendaciones", "recomiendes", "recomendas", "recommendation", "recommend", "cafe", "cafes", "coffee", "restaurant", "restaurants", "restaurante", "restaurantes", "comer", "cenar", "food", "grocery", "supermarket", "supermercado", "pharmacy", "farmacia", "transport", "transporte", "attraction", "atraccion", "visitar", "lugar", "lugares", "cerca", "nearby"],
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
    fields: ["wifi", "wifi_name", "wifi_password", "internet", "network"],
    terms: ["wifi", "wi-fi", "internet", "red", "network", "contrasena", "contraseña", "clave", "password"],
  },
  {
    category: "appliance",
    intent: "appliance_instructions",
    fields: ["appliance", "appliances", "appliance_name", "washer", "coffee_machine", "air_conditioner", "tv", "oven", "microwave", "dishwasher", "dryer"],
    terms: ["electrodomestico", "electrodomesticos", "lavarropas", "lavadora", "lavar", "washer", "laundry", "cafetera", "cafe", "coffee", "aire", "acondicionado", "calefaccion", "prendo", "enciendo", "air", "conditioner", "tv", "television", "netflix", "horno", "oven", "microondas", "microwave", "lavavajillas"],
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
  const conversationalClassification = classifyConversationalOnly(guestMessage);
  const repairDiagnostic = shouldRepairDecisionDiagnostic(decision);
  const candidateAudit = conversationalClassification ? [] : rankedCandidateAudit(guestMessage, evidenceCatalog);
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

  if (conversationalClassification) {
    return withGroundedAudit(
      conversationalOnlyBuild(decision, conversationalClassification),
      buildAudit(baseAudit, [], "conversational_only", null, {
        strategy: "direct_reply",
        inferredIntent: conversationalClassification.kind === "greeting" ? "greeting" : "small_talk",
        scores: { answer_confidence: 100, evidence_relevance_score: 0, safety_score: 100 },
      }),
    );
  }

  if (!repairDiagnostic.value) {
    return withGroundedAudit(
      { decision, override: null },
      buildAudit(baseAudit, [], null, "decision_does_not_need_repair", {
        strategy: strategyForExistingDecision(decision),
        scores: scoresForExistingDecision(decision, candidateAudit),
      }),
    );
  }

  if (ambiguousSensitiveRequest(guestMessage) && attempts < thresholds.max_clarification_attempts) {
    const clarification = sensitiveClarificationDecision(decision, payload, previousOutcome);
    return withGroundedAudit(
      clarification,
      buildAudit(baseAudit, [], "partial_evidence", null, {
        strategy: "clarify_before_escalate",
        inferredIntent: "sensitive_access",
        clarificationQuestion: clarification.decision.message_body || null,
        ambiguityCandidates: ["wifi", "door_code", "safe_code", "lockbox_code"],
        scores: scoresForClarification([], thresholds, { safetyScore: 70 }),
      }),
    );
  }

  let candidates = rankedCandidates(guestMessage, evidenceCatalog);
  if (candidates.length === 0 && neutralRecommendationPreference(guestMessage, payload)) {
    candidates = recommendationFallbackCandidates(evidenceCatalog);
  }
  if (candidates.length === 0) {
    const requestedSensitive = requestedSensitiveType(guestMessage);
    if (requestedSensitive) {
      const missingSensitive = missingSensitiveInformationDecision(decision, payload, previousOutcome, requestedSensitive);
      return withGroundedAudit(
        missingSensitive,
        buildAudit(baseAudit, [], null, "missing_requested_sensitive_information", {
          strategy: "escalation_last_resort",
          inferredIntent: "missing_sensitive_information",
          inferenceReason: `missing_sensitive_type:${requestedSensitive}`,
          scores: scoresForEscalation([], thresholds),
        }),
      );
    }

    if (ambiguousSensitiveRequest(guestMessage) && attempts < thresholds.max_clarification_attempts) {
      const clarification = sensitiveClarificationDecision(decision, payload, previousOutcome);
      return withGroundedAudit(
        clarification,
        buildAudit(baseAudit, [], "partial_evidence", null, {
          strategy: "clarify_before_escalate",
          inferredIntent: "sensitive_access",
          clarificationQuestion: clarification.decision.message_body || null,
          ambiguityCandidates: ["wifi", "door_code", "safe_code", "lockbox_code"],
          scores: scoresForClarification([], thresholds, { safetyScore: 70 }),
        }),
      );
    }

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

    if (attempts >= thresholds.max_clarification_attempts && exhaustedClarificationTopic(guestMessage, payload)) {
      const escalation = escalationLastResortDecision(decision, payload, previousOutcome, clarificationIntent);
      return withGroundedAudit(
        escalation,
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

  const sufficientGroup = sufficientEvidenceGroup(candidates, thresholds);
  const sufficient = sufficientGroup?.candidates || [];
  const sufficiencyAudit = sufficientCandidateAudit(candidates, sufficient);
  if (sufficient.length > 0) {
    const approvalCandidates = sufficient.filter((candidate) => approvalRequired(candidate.evidence));
    const replyCandidates = sufficient.filter((candidate) => !approvalRequired(candidate.evidence));
    if (approvalCandidates.length > 0 && (approvalRequest(guestMessage) || replyCandidates.length === 0)) {
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

    const groundedReplyCandidates = replyCandidates.length > 0 ? replyCandidates : sufficient;
    const strategy = groundedReplyCandidates.some((candidate) => candidate.strategy === "inference") ? "reply_with_inference" : "direct_reply";
    const replyScores = scoresForCandidates(groundedReplyCandidates, thresholds, { safetyScore: 95 });
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
      replyDecision(decision, payload, groundedReplyCandidates, previousOutcome, strategy),
      buildAudit(baseAudit, sufficiencyAudit, "sufficient_evidence", null, {
        strategy,
        inferredIntent: groundedReplyCandidates[0]?.inferred_intent || null,
        inferenceReason: groundedReplyCandidates[0]?.inference_reason || null,
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

  const bestAvailableGroup = groupedCandidatesByIntent(candidates)[0];
  if (bestAvailableGroup?.candidates?.length > 0) {
    const bestCandidates = bestAvailableGroup.candidates.filter((candidate) => !approvalRequired(candidate.evidence));
    if (bestCandidates.length > 0) {
      return withGroundedAudit(
        replyDecision(decision, payload, bestCandidates, previousOutcome, "reply_with_inference"),
        buildAudit(baseAudit, sufficiencyAudit, "sufficient_evidence", null, {
          strategy: "reply_with_inference",
          inferredIntent: bestCandidates[0]?.inferred_intent || "ambiguous_request",
          inferenceReason: bestCandidates[0]?.inference_reason || "clarification_attempts_exhausted_best_available",
          scores: scoresForCandidates(bestCandidates, thresholds, { safetyScore: 85 }),
        }),
      );
    }
  }

  const escalation = escalationLastResortDecision(decision, payload, previousOutcome, "ambiguous_request");
  return withGroundedAudit(
    escalation,
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
  if (outcome === "ask_clarifying_question") return { value: true, reason: "clarification_requires_loop_and_evidence_check" };

  return { value: false, reason: "decision_already_grounded_or_not_repairable" };
}

function rankedCandidates(message: string, evidenceCatalog: EvidenceCatalogEntry[]) {
  const queryTokens = tokens(message);
  const queryCategories = queryIntentCategories(message);
  const recommendationContext = recommendationRequestContext(message, null);
  const requestedSensitive = requestedSensitiveType(message);
  if (queryTokens.length === 0 && queryCategories.length === 0) return [];

  return evidenceCatalog
    .map((evidence) => {
      const debug = scoreEvidenceWithDebug(queryTokens, evidence, queryCategories);
      const compatibility = evidenceCompatibilityForRequest(evidence, {
        requestedSensitive,
        recommendationContext,
      });
      return {
        evidence,
        score: compatibility.compatible ? debug.score + compatibility.score_bonus : 0,
        matched_terms: debug.matched_terms,
        semantic_matches: compatibility.semantic_match ? unique(debug.semantic_matches.concat(compatibility.semantic_match)) : debug.semantic_matches,
        strategy: debug.strategy,
        inferred_intent: compatibility.inferred_intent || debug.inferred_intent,
        inference_reason: compatibility.reason || debug.inference_reason,
      };
    })
    .filter((candidate) => candidate.score > 0 && evidenceUsableForGuest(candidate.evidence))
    .sort(compareCandidates);
}

function sufficientEvidenceGroup(candidates: Candidate[], thresholds: DecisionThresholds): EvidenceGroup | null {
  const groups = groupedCandidatesByIntent(candidates);
  const topGroup = groups[0];
  if (!topGroup) return null;

  const topPriority = topGroup.source_priority;
  const topScore = topGroup.top_score;
  if (clampScore(Math.round(topScore * 20)) < thresholds.medium_score_threshold) return null;

  const topGroups = groups.filter((group) => group.source_priority === topPriority && group.top_score === topScore);
  if (topGroups.length !== 1) return null;

  return topGroup;
}

function groupedCandidatesByIntent(candidates: Candidate[]) {
  const groups = new Map<string, Candidate[]>();
  for (const candidate of candidates) {
    const key = candidate.inferred_intent || inferredIntent(candidate.evidence);
    groups.set(key, (groups.get(key) || []).concat(candidate));
  }

  return Array.from(groups.entries()).map(([intent, intentCandidates]) => {
    const sourcePriorityRank = Math.min(...intentCandidates.map((candidate) => sourcePriority(candidate.evidence)));
    const preferredCandidates = intentCandidates.filter((candidate) => sourcePriority(candidate.evidence) === sourcePriorityRank);
    const topScore = Math.max(...preferredCandidates.map((candidate) => candidate.score));
    const compatibleCandidates = preferredCandidates
      .filter((candidate) => candidate.score >= Math.max(1, topScore - 2))
      .sort(compareCandidates);

    return {
      intent,
      candidates: compatibleCandidates,
      top_score: topScore,
      source_priority: sourcePriorityRank,
    };
  }).sort((left, right) => left.source_priority - right.source_priority || right.top_score - left.top_score);
}

function compareCandidates(left: Candidate, right: Candidate) {
  return sourcePriority(left.evidence) - sourcePriority(right.evidence) ||
    right.score - left.score;
}

function sourcePriority(evidence: EvidenceCatalogEntry) {
  const sourceType = String(evidence.source_type || "");
  const category = String(evidence.category || "");
  if (sourceType === "property_fact" || sourceType === "reservation_fact" || sourceType === "policy") return 1;
  if (evidence.sensitivity || evidence.authorization_required || evidence.tool_name === "sensitive_access_info") return 2;
  if (sourceType === "knowledge_block" && category === "appliances") return 3;
  if (sourceType === "faq") return 4;
  if (sourceType === "knowledge_block") return 5;
  if (sourceType === "recommendation") return 6;
  return 9;
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
    ? inferredResponseFromEvidence(primary, language, candidates[0].inferred_intent, candidates, payload?.guest_message || "")
    : responseFromEvidenceGroup(candidates, language, payload?.guest_message || "");

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
      sensitive_info_used: Boolean(decision?.sensitive_info_used) || candidates.some((candidate) => sensitiveEvidence(candidate.evidence)),
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

function conversationalOnlyBuild(
  decision: any,
  classification: NonNullable<ReturnType<typeof classifyConversationalOnly>>,
): GroundedDecisionBuild {
  const intentType = classification.kind === "greeting" ? "greeting" : "small_talk";

  return {
    override: {
      applied: true,
      reason: "sufficient_evidence",
      evidence_ids: [],
      sufficiency: "sufficient",
      previous_outcome: String(decision?.outcome || decision?.decision || "") || null,
    },
    decision: {
      ...decision,
      outcome: "reply",
      decision: "reply",
      language: classification.language,
      message_body: classification.response,
      response_text: classification.response,
      safe_fallback_response: decision?.safe_fallback_response || classification.response,
      intent_summary: `Conversational ${classification.kind}`,
      detected_intents: [{ type: intentType, status: "answered" }],
      evidence_ids: [],
      used_source_ids: [],
      required_capabilities: [],
      proposed_action: null,
      sensitive_info_used: false,
      escalation: {
        required: false,
        reason_code: null,
        summary_for_host: null,
      },
      escalation_required: false,
      escalation_reason: null,
      missing_information: [],
      safety_flags: [],
      confidence: 1,
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

function sensitiveClarificationDecision(
  decision: any,
  payload: any,
  previousOutcome: string | null,
): GroundedDecisionBuild {
  const language = normalizedLanguage(decision?.language || payload?.guest_language_fallback || "en");
  const messageBody = sensitiveClarificationMessage(language);

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
      intent_summary: "The guest asked for a sensitive access detail but the exact type is ambiguous.",
      detected_intents: [{
        type: "sensitive_access",
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
      missing_information: ["sensitive_access_type"],
      safety_flags: removeFallbackFlag(decision?.safety_flags),
      confidence: Math.max(Number(decision?.confidence || 0), 0.65),
    },
  };
}

function missingSensitiveInformationDecision(
  decision: any,
  payload: any,
  previousOutcome: string | null,
  requestedSensitive: string,
): GroundedDecisionBuild {
  const language = normalizedLanguage(decision?.language || payload?.guest_language_fallback || "en");
  const messageBody = missingSensitiveInformationMessage(language);

  return {
    override: {
      applied: true,
      reason: "missing_sensitive_information",
      evidence_ids: [],
      sufficiency: "insufficient",
      previous_outcome: previousOutcome,
    },
    decision: {
      ...decision,
      outcome: "escalate",
      decision: "escalate",
      language,
      message_body: messageBody,
      response_text: messageBody,
      safe_fallback_response: decision?.safe_fallback_response || messageBody,
      intent_summary: `Missing sensitive information: ${requestedSensitive}.`,
      detected_intents: [{
        type: "missing_sensitive_information",
        status: "escalated",
      }],
      evidence_ids: [],
      used_source_ids: [],
      required_capabilities: ["owner_attention"],
      proposed_action: null,
      escalation: {
        required: true,
        reason_code: "missing_sensitive_information",
        summary_for_host: `Falta cargar ${requestedSensitive} para responder al huésped.`,
      },
      escalation_required: true,
      escalation_reason: "missing_sensitive_information",
      missing_information: [requestedSensitive],
      safety_flags: removeFallbackFlag(decision?.safety_flags),
      confidence: Math.max(Number(decision?.confidence || 0), 0.6),
    },
  };
}

function escalationLastResortDecision(
  decision: any,
  payload: any,
  previousOutcome: string | null,
  intent: string,
): GroundedDecisionBuild {
  const language = normalizedLanguage(decision?.language || payload?.guest_language_fallback || "en");
  const messageBody = decision?.safe_fallback_response || escalationLastResortMessage(language);

  return {
    override: null,
    decision: {
      ...decision,
      outcome: "escalate",
      decision: "escalate",
      language,
      message_body: messageBody,
      response_text: messageBody,
      intent_summary: "Clarification limit reached without enough evidence to answer safely.",
      detected_intents: [{
        type: intent,
        status: "escalated",
      }],
      evidence_ids: [],
      used_source_ids: [],
      required_capabilities: ["owner_attention"],
      proposed_action: null,
      escalation: {
        required: true,
        reason_code: "clarification_limit_reached",
        summary_for_host: `No se pudo resolver la consulta luego de pedir aclaración. Pregunta original: ${payload?.guest_message || ""}`,
      },
      escalation_required: true,
      escalation_reason: "clarification_limit_reached",
      missing_information: ["owner_answer"],
      safety_flags: removeFallbackFlag(decision?.safety_flags),
      confidence: Math.max(Number(decision?.confidence || 0), 0.45),
    },
  };
}

function responseFromEvidenceGroup(candidates: Candidate[], language: string, guestMessage = "") {
  if (candidates.length === 0) return "";
  const entries = uniqueEvidence(candidates.map((candidate) => candidate.evidence));

  const access = accessResponseFromGroup(entries, language, guestMessage);
  if (access) return access;

  const recommendation = recommendationResponseFromGroup(entries, language, guestMessage);
  if (recommendation) return sentence(recommendation);

  if (entries.length === 1) return responseFromEvidence(entries[0], language);

  return sentence(entries.map((entry) => `${fieldDisplayLabel(entry, language)}: ${String(entry.value || "").trim()}`).filter((part) => !part.endsWith(":")).join(". "));
}

function responseFromEvidence(evidence: EvidenceCatalogEntry, language: string) {
  const value = String(evidence.value || "").trim();
  const label = humanLabel(evidence);
  const intent = inferredIntent(evidence);

  if (["check_in_time", "check_out_time", "parking", "address", "access"].includes(intent)) {
    return directResponseForIntent(value, language, intent);
  }

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

  return fallbackLabeledResponse(fieldDisplayLabel(evidence, language) || label, value, language);
}

function inferredResponseFromEvidence(evidence: EvidenceCatalogEntry, language: string, intent: string, candidates: Candidate[] = [], guestMessage = "") {
  const value = String(evidence.value || "").trim();
  if (candidates.length > 1) return responseFromEvidenceGroup(candidates, language, guestMessage);
  if (intent === "access") {
    return accessResponseFromGroup([evidence], language, guestMessage) || directResponseForIntent(value, language, intent) || responseFromEvidence(evidence, language);
  }
  return directResponseForIntent(value, language, intent) || responseFromEvidence(evidence, language);
}

function directResponseForIntent(value: string, language: string, intent: string) {
  if (intent === "check_in_time") {
    if (language === "es") return `El check-in es a las ${value}.`;
    if (language === "fr") return `Le check-in est à ${value}.`;
    return `Check-in is at ${value}.`;
  }
  if (intent === "check_out_time") {
    if (language === "es") return `El checkout es a las ${value}.`;
    if (language === "fr") return `Le check-out est à ${value}.`;
    return `Checkout is at ${value}.`;
  }
  if (intent === "parking") {
    if (language === "es") return `La información de estacionamiento es: ${value}.`;
    if (language === "fr") return `Les informations de stationnement sont : ${value}.`;
    return `Parking information: ${value}.`;
  }
  if (intent === "address") {
    if (language === "es") return `La dirección es: ${value}.`;
    if (language === "fr") return `L'adresse est : ${value}.`;
    return `The address is: ${value}.`;
  }
  if (intent === "access") {
    if (language === "es") return `Para entrar: ${value}.`;
    if (language === "fr") return `Pour entrer : ${value}.`;
    return `To enter: ${value}.`;
  }

  return null;
}

function fallbackLabeledResponse(label: string, value: string, language: string) {
  if (language === "es") return `${label}: ${value}.`;
  if (language === "fr") return `${label} : ${value}.`;
  return `${label}: ${value}.`;
}

function recommendationResponseFromGroup(entries: EvidenceCatalogEntry[], language: string, guestMessage = "") {
  if (!entries.some((entry) => entry.source_type === "recommendation")) return null;

  const recommendationEntries = entries.filter((entry) => entry.source_type === "recommendation");
  const preference = requestedRecommendationPreference(guestMessage);
  const missingPreference = preference && !recommendationEntries.some((entry) => {
    const haystack = normalizeText([entry.label, entry.value, entry.category, entry.metadata.address].filter(Boolean).join(" "));
    return looseTokens(preference).some((token) => haystack.includes(token));
  });
  const prefix = missingPreference ? noExactRecommendationPrefix(preference, language) : "";

  const body = recommendationEntries.map((entry) => {
    const details = [
      humanLabel(entry),
      entry.value,
      entry.metadata.address,
      entry.metadata.distance_or_walking_time,
      entry.metadata.google_maps_url,
    ].filter(Boolean).join(" - ");
    return details;
  }).filter(Boolean).join(". ");

  return [prefix, body].filter(Boolean).join(" ");
}

function noExactRecommendationPrefix(preference: string, language: string) {
  if (language === "es") return `No tengo una recomendación específica de ${preference} registrada. Opciones guardadas:`;
  if (language === "fr") return `Je n'ai pas de recommandation spécifique pour ${preference}. Options enregistrées :`;
  if (language === "pt") return `Não tenho uma recomendação específica de ${preference} registrada. Opções salvas:`;
  return `I don't have a specific recommendation for ${preference} saved. Saved options:`;
}

function accessResponseFromGroup(entries: EvidenceCatalogEntry[], language: string, guestMessage = "") {
  const accessEntries = entries.filter((entry) => inferredIntent(entry) === "access");
  if (accessEntries.length === 0) return null;

  const allLines = accessEntries.flatMap(accessEvidenceLines);
  const detailed = detailedAccessRequest(guestMessage);
  const codeFocused = accessCodeRequest(guestMessage);
  const lines = codeFocused
    ? prioritizedAccessCodeLines(allLines)
    : allLines;
  const selected = unique(lines).slice(0, detailed ? 12 : 6);
  if (selected.length === 0) return null;

  const prefix = accessPrefix(language);
  if (detailed || selected.length > 1) {
    return `${prefix}\n${selected.map((line) => `- ${line}`).join("\n")}`;
  }

  return directResponseForIntent(selected[0], language, "access");
}

function accessEvidenceLines(entry: EvidenceCatalogEntry) {
  const value = String(entry.value || "").trim();
  if (value.length === 0) return [];

  const field = evidenceField(entry);
  const lines = accessInstructionLines(value);
  if (field === "access_code" || field === "entry_code") {
    const label = String(entry.label || field).toLowerCase().includes("code") || String(entry.label || field).toLowerCase().includes("codigo")
      ? humanLabel(entry)
      : "Código de acceso";
    if (lines.length <= 1) return [`${label}: ${value}`];
  }

  return lines;
}

function accessInstructionLines(value: string) {
  return value
    .split(/\r?\n|[;•]+|(?<=\.)\s+(?=[A-ZÁÉÍÓÚÑa-záéíóúñ0-9])/u)
    .map((line) => line.replace(/^[-*]\s*/, "").trim())
    .filter((line) => line.length > 0);
}

function detailedAccessRequest(message: string) {
  const text = normalizeText(message);
  return /\b(detalle|detallad|completo|paso a paso|full|details|detailed|complete|step by step)\b/.test(text);
}

function accessCodeRequest(message: string) {
  const text = normalizeText(message);
  return /\b(codigo|code|clave|pin|caja|lockbox|llave|key|cerradura|consejeria|portero)\b/.test(text);
}

function prioritizedAccessCodeLines(lines: string[]) {
  const important = lines.filter((line) => accessCodeRequest(line));
  const rest = lines.filter((line) => !accessCodeRequest(line));
  return important.concat(rest);
}

function accessPrefix(language: string) {
  if (language === "es") return "Para entrar:";
  if (language === "fr") return "Pour entrer :";
  if (language === "pt") return "Para entrar:";
  return "To enter:";
}

function fieldDisplayLabel(evidence: EvidenceCatalogEntry, language: string) {
  const field = evidenceField(evidence);
  const labels: Record<string, Record<string, string>> = {
    wifi_name: { es: "Red de WiFi", fr: "Réseau WiFi", en: "WiFi network" },
    wifi_password: { es: "Contraseña de WiFi", fr: "Mot de passe WiFi", en: "WiFi password" },
    parking: { es: "Estacionamiento", fr: "Stationnement", en: "Parking" },
    parking_available: { es: "Estacionamiento disponible", fr: "Stationnement disponible", en: "Parking availability" },
    parking_instructions: { es: "Instrucciones de estacionamiento", fr: "Instructions de stationnement", en: "Parking instructions" },
    check_in_time: { es: "Check-in", fr: "Check-in", en: "Check-in" },
    early_check_in_policy: { es: "Política de early check-in", fr: "Politique d'arrivée anticipée", en: "Early check-in policy" },
    check_out_time: { es: "Checkout", fr: "Check-out", en: "Checkout" },
    late_check_out_policy: { es: "Política de late checkout", fr: "Politique de départ tardif", en: "Late checkout policy" },
    access_instructions: { es: "Instrucciones de acceso", fr: "Instructions d'accès", en: "Access instructions" },
    access_code: { es: "Código de acceso", fr: "Code d'accès", en: "Access code" },
    address: { es: "Dirección", fr: "Adresse", en: "Address" },
  };

  return labels[field]?.[language] || labels[field]?.en || humanLabel(evidence);
}

function sentence(value: string) {
  const trimmed = value.trim();
  if (trimmed.length === 0) return "";
  return /[.!?]$/.test(trimmed) ? trimmed : `${trimmed}.`;
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

function sensitiveClarificationMessage(language: string) {
  if (language === "es") return "¿Qué dato necesitás exactamente: WiFi, puerta, caja fuerte, caja de llaves u otro acceso?";
  if (language === "fr") return "De quelle information avez-vous besoin exactement : WiFi, porte, coffre-fort, boîte à clés ou autre accès ?";
  if (language === "pt") return "De qual dado você precisa exatamente: WiFi, porta, cofre, caixa de chaves ou outro acesso?";
  return "Which detail do you need exactly: WiFi, door, safe, lockbox, or another access detail?";
}

function missingSensitiveInformationMessage(language: string) {
  if (language === "es") return "No tengo esa información confirmada. Lo consulto con el anfitrión y te aviso.";
  if (language === "fr") return "Je n'ai pas cette information confirmée. Je vérifie avec l'hôte et je vous tiens au courant.";
  if (language === "pt") return "Não tenho essa informação confirmada. Vou consultar o anfitrião e te aviso.";
  return "I don't have that confirmed information. I'll check with the host and get back to you.";
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
  if (category === "appliance") {
    if (language === "es") return "No tengo instrucciones cargadas para ese electrodoméstico. ¿Querés que lo consulte con el anfitrión?";
    if (language === "fr") return "Je n'ai pas d'instructions enregistrées pour cet appareil. Voulez-vous que je demande à l'hôte ?";
    return "I don't have instructions saved for that appliance. Would you like me to check with the host?";
  }
  if (category === "recommendation") {
    if (language === "es") return "No tengo recomendaciones guardadas para esa consulta todavía. ¿Querés que lo consulte con el anfitrión?";
    if (language === "fr") return "Je n'ai pas encore de recommandations enregistrées pour cette demande. Voulez-vous que je demande à l'hôte ?";
    if (language === "pt") return "Ainda não tenho recomendações salvas para essa consulta. Quer que eu consulte o anfitrião?";
    return "I don't have saved recommendations for that request yet. Would you like me to check with the host?";
  }

  if (language === "es") return "¿Me aclarás un poco más a qué te referís?";
  if (language === "fr") return "Pouvez-vous préciser un peu ce que vous voulez dire ?";
  return "Can you clarify a bit what you mean?";
}

function escalationLastResortMessage(language: string) {
  if (language === "es") return "No tengo esa información confirmada. Lo consulto con el anfitrión y te aviso.";
  if (language === "fr") return "Je n'ai pas cette information confirmée. Je vérifie avec l'hôte et je vous tiens au courant.";
  if (language === "pt") return "Não tenho essa informação confirmada. Vou consultar o anfitrião e te aviso.";
  return "I don't have that confirmed information. I'll check with the host and get back to you.";
}

function summaryForHost(payload: any, evidence: EvidenceCatalogEntry) {
  return `El huésped pidió algo relacionado con ${humanLabel(evidence)} y la política encontrada requiere aprobación. Pregunta original: ${payload?.guest_message || ""}`;
}

function approvalRequired(evidence: EvidenceCatalogEntry) {
  const text = [evidence.value, evidence.text].join(" ");
  return APPROVAL_PATTERNS.some((pattern) => pattern.test(text));
}

function approvalRequest(message: string) {
  const text = normalizeText(message);
  return /\b(puedo|puede|podria|podrias|can|could|may|allowed|permitido|autoriz|aprobar|approval|antes|temprano|early|tarde|late|extender|extension|after|before|despues)\b/.test(text);
}

function evidenceCompatibilityForRequest(
  evidence: EvidenceCatalogEntry,
  context: {
    requestedSensitive: string | null;
    recommendationContext: ReturnType<typeof recommendationRequestContext>;
  },
) {
  const sensitiveType = evidenceSensitiveType(evidence);
  if (context.requestedSensitive && sensitiveEvidence(evidence)) {
    if (sensitiveType !== context.requestedSensitive) {
      return {
        compatible: false,
        score_bonus: 0,
        semantic_match: null,
        inferred_intent: null,
        reason: `sensitive_type_mismatch:${context.requestedSensitive}:${sensitiveType || "unknown"}`,
      };
    }

    return {
      compatible: true,
      score_bonus: 8,
      semantic_match: "sensitive",
      inferred_intent: canonicalIntentName(context.requestedSensitive.replace(/^property\./, "")),
      reason: `sensitive_type_match:${context.requestedSensitive}`,
    };
  }

  if (evidence.source_type === "recommendation" && context.recommendationContext.category) {
    const category = normalizedRecommendationCategory(evidence.category);
    if (!recommendationCategoryCompatible(context.recommendationContext.category, category)) {
      return {
        compatible: false,
        score_bonus: 0,
        semantic_match: null,
        inferred_intent: null,
        reason: `recommendation_category_mismatch:${context.recommendationContext.category}:${category || "unknown"}`,
      };
    }
  }

  return {
    compatible: true,
    score_bonus: evidence.source_type === "recommendation" && context.recommendationContext.category ? 4 : 0,
    semantic_match: evidence.source_type === "recommendation" && context.recommendationContext.category ? "recommendation" : null,
    inferred_intent: evidence.source_type === "recommendation" ? recommendationIntentForCategory(context.recommendationContext.category || evidence.category) : null,
    reason: null,
  };
}

function requestedSensitiveType(message: string) {
  const text = normalizeText(message);
  const messageTokens = looseTokens(message);
  const hasSecretLanguage = sensitiveSecretLanguage(messageTokens, text);
  if (!hasSecretLanguage) return null;

  const matches = sensitiveTypeMatches(messageTokens, text);
  if (matches.length === 1) return matches[0].definition.type;
  if (matches.length > 1 && matches[0].score > matches[1].score) return matches[0].definition.type;
  return null;
}

function ambiguousSensitiveRequest(message: string) {
  const text = normalizeText(message);
  const messageTokens = looseTokens(message);
  if (!sensitiveSecretLanguage(messageTokens, text)) return false;
  if (/\b(acceso|entrada|entrar|ingresar|ingreso|access|entry)\b/.test(text)) return false;

  const matches = sensitiveTypeMatches(messageTokens, text);
  return matches.length !== 1;
}

function sensitiveSecretLanguage(messageTokens: string[], normalizedText: string) {
  return SENSITIVE_TYPE_DEFINITIONS.some((definition) => intersects(messageTokens, definition.secretTerms)) ||
    /\b(codigo|code|clave|contrasena|contraseña|password|pin|donde esta|ubicacion)\b/.test(normalizedText);
}

function sensitiveTypeMatches(messageTokens: string[], normalizedText: string) {
  return SENSITIVE_TYPE_DEFINITIONS
    .map((definition) => {
      const matchedTerms = definition.terms.filter((term) => messageTokens.includes(term));
      let score = matchedTerms.length;
      if (definition.type === "property.safe_code" && /\bcaja fuerte\b|\bsafe\b/.test(normalizedText)) score += 3;
      if (definition.type === "property.lockbox_code" && /\bcaja de llaves\b|\blockbox\b|\bkeybox\b/.test(normalizedText)) score += 3;
      if (definition.type === "property.building_access_code" && /\bedificio\b|\bbuilding\b/.test(normalizedText)) score += 2;
      if (definition.type === "property.door_code" && /\bpuerta\b|\bdoor\b/.test(normalizedText)) score += 2;
      if (definition.type === "property.gate_code" && /\bporton\b|\bportón\b|\bgate\b/.test(normalizedText)) score += 2;
      return { definition, score };
    })
    .filter((match) => match.score > 0)
    .sort((left, right) => right.score - left.score);
}

function evidenceSensitiveType(evidence: EvidenceCatalogEntry) {
  const metadataType = typeof evidence.metadata?.sensitive_type === "string" ? evidence.metadata.sensitive_type : null;
  if (metadataType) return canonicalSensitiveType(metadataType);

  const field = evidenceField(evidence);
  const evidenceId = String(evidence.evidence_id || "");
  return canonicalSensitiveType(evidenceId) || canonicalSensitiveType(field);
}

function canonicalSensitiveType(value: unknown) {
  const normalized = String(value || "")
    .replace(/^property[._:-]/, "property.")
    .replace(/^property_fact[:._-]/, "property.")
    .replace(/^sensitive_/, "property.")
    .replace(/_/g, "_");
  if (normalized === "property.wifi_password") return normalized;
  if (normalized === "property.wifi_name") return normalized;
  const found = SENSITIVE_TYPE_DEFINITIONS.find((definition) => normalized === definition.type || normalized.endsWith(`.${definition.type.replace("property.", "")}`));
  return found?.type || null;
}

function recommendationRequestContext(message: string, payload: any) {
  const categoryFromMessage = requestedRecommendationCategory(message);
  if (categoryFromMessage) {
    return {
      category: categoryFromMessage,
      preference: requestedRecommendationPreference(message),
    };
  }

  if (neutralRecommendationPreference(message, payload)) {
    return {
      category: requestedRecommendationCategory(conversationHistoryText(payload?.conversation_history)),
      preference: null,
    };
  }

  return {
    category: null,
    preference: null,
  };
}

function requestedRecommendationCategory(message: string) {
  const messageTokens = looseTokens(message);
  for (const [category, aliases] of Object.entries(RECOMMENDATION_CATEGORY_ALIASES)) {
    if (intersects(messageTokens, aliases)) return category;
  }
  return queryIntentCategories(message).includes("recommendation") ? "other" : null;
}

function requestedRecommendationPreference(message: string) {
  const rawTokens = looseTokens(message);
  const preferenceTokens = rawTokens.filter((token) => !STOPWORDS.has(token) && !GENERIC_RECOMMENDATION_TERMS.has(token));
  return unique(preferenceTokens).slice(0, 3).join(" ").trim() || null;
}

function normalizedRecommendationCategory(category: unknown) {
  const normalized = normalizeText(String(category || ""));
  if (["food", "dining", "comida"].includes(normalized)) return "restaurant";
  if (["grocery", "groceries", "market", "mercado", "almacen"].includes(normalized)) return "supermarket";
  if (["coffee", "breakfast", "desayuno"].includes(normalized)) return "cafe";
  if (["activities", "activity", "visit"].includes(normalized)) return "attraction";
  return normalized || null;
}

function recommendationCategoryCompatible(requested: string | null, evidenceCategory: string | null) {
  if (!requested || requested === "other") return true;
  const requestedCategory = normalizedRecommendationCategory(requested);
  const category = normalizedRecommendationCategory(evidenceCategory);
  if (!requestedCategory || !category) return true;
  return requestedCategory === category;
}

function recommendationIntentForCategory(category: unknown) {
  const normalized = normalizedRecommendationCategory(category);
  if (normalized === "restaurant") return "restaurant_recommendation";
  if (normalized === "cafe") return "cafe_recommendation";
  if (normalized === "supermarket") return "supermarket_recommendation";
  if (normalized === "pharmacy") return "pharmacy_recommendation";
  if (normalized === "transport") return "transport_recommendation";
  if (normalized === "attraction") return "nearby_places";
  return "local_recommendations";
}

function evidenceUsableForGuest(evidence: EvidenceCatalogEntry) {
  return !(sensitiveEvidence(evidence) && evidence.authorized === false);
}

function sensitiveEvidence(evidence: EvidenceCatalogEntry) {
  return evidence.authorization_required || evidence.sensitivity != null;
}

function inferredIntent(evidence: EvidenceCatalogEntry) {
  return canonicalIntentName(snakeCase(evidence.field || evidence.label || evidence.category || evidence.source_type || "grounded_answer"));
}

function canonicalIntentName(intent: string) {
  if (intent === "checkin_time" || intent === "check_in" || intent === "checkin") return "check_in_time";
  if (intent === "early_checkin_policy" || intent === "early_check_in_policy" || intent === "arrival_time") return "check_in_time";
  if (intent === "checkout_time" || intent === "check_out" || intent === "checkout") return "check_out_time";
  if (intent === "late_checkout_policy" || intent === "late_check_out_policy" || intent === "departure_time") return "check_out_time";
  if (intent === "parking_available" || intent === "parking_availability" || intent === "parking_instructions" || intent === "garage" || intent === "cochera" || intent === "estacionamiento") return "parking";
  if (intent === "access_instructions" || intent === "access_code" || intent === "entry_code" || intent === "entrance" || intent === "entry" || intent === "lockbox" || intent === "key" || intent === "keys" || intent === "codigo" || intent === "llave") return "access";
  if (intent === "wifi_name" || intent === "wifi_password" || intent === "wi_fi" || intent === "internet" || intent === "network") return "wifi";
  if (intent === "appliances" || intent === "appliance" || intent === "washer" || intent === "coffee_machine" || intent === "air_conditioner" || intent === "tv" || intent === "oven" || intent === "microwave" || intent === "dishwasher" || intent === "dryer") return "appliance_instructions";
  if (["recommendations", "restaurant", "food", "cafe", "grocery", "supermarket", "pharmacy", "transport", "attraction", "place"].includes(intent)) return "recommendation";
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
  const timedAccessLanguage = intersects(rawTokens, ["entrar", "ingresar", "ingreso", "entrada"]);
  if (hasTimeLanguage && genericArrivalOrDeparture) categories.push("arrival", "departure");
  if (hasTimeLanguage && timedAccessLanguage) categories.push("arrival");
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
  const categories = queryIntentCategories(message);
  if (categories.includes("issue")) return "issue";
  if (categories.includes("appliance")) return "appliance";
  if (categories.includes("recommendation")) return "recommendation";
  return null;
}

function exhaustedClarificationTopic(message: string, payload: any) {
  return Boolean(clarificationCategory(message) || neutralRecommendationPreference(message, payload));
}

function neutralRecommendationPreference(message: string, payload: any) {
  const text = normalizeText(message);
  const neutral = /\b(me da igual|como sea|cualquiera|lo que recomiendes|lo que recomendas|recomendame vos|todo sirve|no importa|me es igual|anything|whatever|up to you|your choice|anywhere|qualquer|tanto faz|voce escolhe|você escolhe)\b/.test(text);
  if (!neutral) return false;

  const history = conversationHistoryText(payload?.conversation_history);
  if (queryIntentCategories(history).includes("recommendation")) return true;
  return /\b(recomendacion|recomendaciones|recomendame|recomendar|recommendation|recommend|cafe|restaurant|restaurante|comer|farmacia|supermercado|pharmacy|grocery|nearby|cerca)\b/.test(normalizeText(history));
}

function recommendationFallbackCandidates(evidenceCatalog: EvidenceCatalogEntry[]): Candidate[] {
  return evidenceCatalog
    .filter((evidence) => evidence.source_type === "recommendation" && evidenceUsableForGuest(evidence))
    .map((evidence) => ({
      evidence,
      score: 5,
      matched_terms: [],
      semantic_matches: ["recommendation"],
      strategy: "inference" as const,
      inferred_intent: "recommendation",
      inference_reason: "neutral_preference_after_recommendation_context",
    }))
    .sort(compareCandidates)
    .slice(0, 6);
}

function conversationHistoryText(history: any) {
  if (!Array.isArray(history)) return "";
  return history
    .slice(-6)
    .map((message: any) => String(message?.body || ""))
    .join(" ");
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
  if (tokens.some((token) => ["wifi", "internet", "red", "network"].includes(token))) {
    expanded.push("wifi", "internet", "network");
  }
  if (tokens.some((token) => ["clave", "contrasena", "contraseña", "password"].includes(token))) {
    expanded.push("password", "wifi_password");
  }
  if (tokens.some((token) => ["visita", "visitas", "invitado", "invitados", "invitar", "gente", "visitor", "visitors", "guests", "friends"].includes(token))) {
    expanded.push("visitors", "permission");
  }
  if (tokens.some((token) => ["cafe", "cafes", "coffee", "restaurant", "restaurants", "restaurante", "restaurantes", "comer", "cenar", "recomendar", "recomendaciones", "recomiendes", "recomendas", "recommendation", "food", "grocery", "supermarket", "supermercado", "pharmacy", "farmacia", "transport", "transporte", "attraction", "atraccion", "visitar", "lugar", "lugares", "nearby", "cerca"].includes(token))) {
    expanded.push("recommendation");
  }
  if (tokens.some((token) => ["supermarket", "supermercado", "grocery", "market", "mercado"].includes(token))) {
    expanded.push("grocery", "supermarket");
  }
  if (tokens.some((token) => ["pharmacy", "farmacia", "drugstore"].includes(token))) {
    expanded.push("pharmacy");
  }
  if (tokens.some((token) => ["restaurant", "restaurants", "restaurante", "restaurantes", "comer", "cenar", "almorzar", "food"].includes(token))) {
    expanded.push("food", "restaurant");
  }
  if (tokens.some((token) => ["transport", "transporte", "taxi", "bus", "uber"].includes(token))) {
    expanded.push("transport");
  }
  if (tokens.some((token) => ["attraction", "atraccion", "visitar", "paseo", "turismo"].includes(token))) {
    expanded.push("attraction");
  }
  if (tokens.some((token) => ["lavarropas", "lavadora", "washer", "laundry"].includes(token))) {
    expanded.push("appliance", "washer");
  }
  if (tokens.some((token) => ["cafetera", "cafe", "coffee"].includes(token))) {
    expanded.push("appliance", "coffee_machine");
  }
  if (tokens.some((token) => ["aire", "acondicionado", "calefaccion", "air", "conditioner"].includes(token))) {
    expanded.push("appliance", "air_conditioner");
  }
  if (tokens.some((token) => ["tv", "television", "netflix"].includes(token))) {
    expanded.push("appliance", "tv");
  }
  if (tokens.some((token) => ["horno", "oven"].includes(token))) {
    expanded.push("appliance", "oven");
  }
  if (tokens.some((token) => ["microondas", "microwave"].includes(token))) {
    expanded.push("appliance", "microwave");
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
  const recommendationContext = recommendationRequestContext(message, null);
  const requestedSensitive = requestedSensitiveType(message);
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
      const compatibility = evidenceCompatibilityForRequest(evidence, {
        requestedSensitive,
        recommendationContext,
      });
      const score = compatibility.compatible ? debug.score + compatibility.score_bonus : 0;
      const reason = compatibility.compatible
        ? (score > 0 ? "included_score_positive" : `excluded_${debug.reason}`)
        : `excluded_${compatibility.reason}`;

      return {
        evidence_id: evidence.evidence_id,
        field: evidence.field || null,
        label: evidence.label || null,
        value: evidence.value ?? null,
        content: evidence.text || null,
        excerpt: String(evidence.metadata?.excerpt || evidence.text || "").slice(0, 500) || null,
        score,
        matched_terms: debug.matched_terms,
        semantic_matches: compatibility.semantic_match ? unique(debug.semantic_matches.concat(compatibility.semantic_match)) : debug.semantic_matches,
        source_type: evidence.source_type || null,
        reason_included_or_excluded: reason,
        inferred_intent: compatibility.inferred_intent || debug.inferred_intent,
        inference_reason: compatibility.reason || debug.inference_reason,
      };
    })
    .sort((left, right) => right.score - left.score);
}

function sufficientCandidateAudit(candidates: Candidate[], sufficient: Candidate[]): SufficientCandidateAudit[] {
  if (candidates.length === 0) return [];

  const sufficientIds = new Set(sufficient.map((candidate) => candidate.evidence.evidence_id));
  const topScore = candidates[0]?.score || 0;
  const topCandidates = candidates.filter((candidate) => candidate.score === topScore);
  const distinctIntents = unique(topCandidates.map((candidate) => candidate.inferred_intent));

  return topCandidates.map((candidate) => {
    let reason = "top_score_meets_threshold_single_intent";
    if (!sufficientIds.has(candidate.evidence.evidence_id)) {
      if (topScore < 3) {
        reason = "score_below_sufficiency_threshold";
      } else if (distinctIntents.length > 1) {
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

function evidenceField(evidence: EvidenceCatalogEntry) {
  return snakeCase(evidence.field || evidence.label || evidence.evidence_id || "");
}

function uniqueEvidence(entries: EvidenceCatalogEntry[]) {
  const seen = new Set<string>();
  return entries.filter((entry) => {
    const key = `${entry.evidence_id}:${JSON.stringify(entry.value)}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
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
