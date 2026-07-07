import assert from "node:assert/strict";
import test from "node:test";
import { buildEvidenceCatalog } from "./evidence-catalog.js";
import { buildGroundedDecision } from "./grounded-decision-builder.js";

test("structured fact evidence answers check-in without unknown escalation", () => {
  const result = buildGroundedDecision(unknownEscalation("es"), {
    guest_message: "a que hora es el check in?",
  }, catalogFromSource({
    source_type: "property_fact",
    source_id: "property_fact:check_in_time",
    evidence_id: "property.check_in_time",
    field: "check_in_time",
    label: "check_in_time",
    value: "15:00",
  }));

  assert.equal(result.override?.reason, "sufficient_evidence");
  assert.equal(result.decision.outcome, "reply");
  assert.equal(result.decision.escalation_required, false);
  assert.notEqual(result.decision.detected_intents[0].type, "unknown");
  assert.deepEqual(result.decision.evidence_ids, ["property.check_in_time"]);
  assert.match(result.decision.message_body, /15:00/);
  assert.equal(result.decision.audit.grounded_decision_builder.should_repair_decision.value, true);
  assert.equal(result.decision.audit.grounded_decision_builder.evidence_catalog_size, 1);
  assert.equal(result.decision.audit.grounded_decision_builder.ranked_candidates[0].evidence_id, "property.check_in_time");
  assert.equal(result.decision.audit.grounded_decision_builder.grounded_decision_result.override_created, true);
  assert.equal(result.decision.audit.grounded_decision_builder.final_decision_source.grounded_override, true);
});

test("structured fact evidence answers checkout", () => {
  const result = buildGroundedDecision(unknownEscalation("es"), {
    guest_message: "y el checkout?",
  }, catalogFromSource({
    source_type: "property_fact",
    source_id: "property_fact:check_out_time",
    evidence_id: "property.check_out_time",
    field: "check_out_time",
    label: "check_out_time",
    value: "11:00",
  }));

  assert.equal(result.decision.outcome, "reply");
  assert.equal(result.decision.escalation_required, false);
  assert.deepEqual(result.decision.evidence_ids, ["property.check_out_time"]);
  assert.match(result.decision.message_body, /11:00/);
});

test("arrival wording replies with inference from check-in evidence", () => {
  const result = buildGroundedDecision(unknownEscalation("es"), {
    guest_message: "a que hora puedo entrar al depto?",
  }, catalogFromSource({
    source_type: "property_fact",
    source_id: "property_fact:check_in_time",
    evidence_id: "property.check_in_time",
    field: "check_in_time",
    label: "check_in_time",
    value: "15:00",
  }));

  assert.equal(result.decision.outcome, "reply");
  assert.equal(result.decision.escalation_required, false);
  assert.deepEqual(result.decision.evidence_ids, ["property.check_in_time"]);
  assert.equal(result.decision.detected_intents[0].type, "check_in_time");
  assert.equal(result.decision.detected_intents[0].status, "answered_with_inference");
  assert.match(result.decision.message_body, /Si te referís al horario de ingreso\/check-in/);
  assert.match(result.decision.message_body, /15:00/);
  assert.equal(result.decision.audit.grounded_decision_builder.final_decision_strategy, "reply_with_inference");
});

test("generic go time with check-in and checkout asks clarification before escalating", () => {
  const result = buildGroundedDecision(unknownEscalation("es"), {
    guest_message: "a que hora puedo ir?",
  }, catalogFromSources([
    {
      source_type: "property_fact",
      source_id: "property_fact:check_in_time",
      evidence_id: "property.check_in_time",
      field: "check_in_time",
      label: "check_in_time",
      value: "15:00",
    },
    {
      source_type: "property_fact",
      source_id: "property_fact:check_out_time",
      evidence_id: "property.check_out_time",
      field: "check_out_time",
      label: "check_out_time",
      value: "11:00",
    },
  ]));

  assert.equal(result.decision.outcome, "ask_clarifying_question");
  assert.equal(result.decision.escalation_required, false);
  assert.equal(result.decision.detected_intents[0].type, "ambiguous_time");
  assert.deepEqual(result.decision.evidence_ids.sort(), ["property.check_in_time", "property.check_out_time"].sort());
  assert.match(result.decision.message_body, /entrada\/check-in/);
  assert.match(result.decision.message_body, /salida\/check-out/);
  assert.equal(result.decision.audit.grounded_decision_builder.final_decision_strategy, "clarify_before_escalate");
});

test("clarification follow-up answers using the same evidence", () => {
  const result = buildGroundedDecision(unknownEscalation("es"), {
    guest_message: "al check in",
    conversation_history: [
      { sender: "ai", body: "¿Te referís al horario de entrada/check-in o al horario de salida/check-out?" },
    ],
  }, catalogFromSources([
    {
      source_type: "property_fact",
      source_id: "property_fact:check_in_time",
      evidence_id: "property.check_in_time",
      field: "check_in_time",
      label: "check_in_time",
      value: "15:00",
    },
    {
      source_type: "property_fact",
      source_id: "property_fact:check_out_time",
      evidence_id: "property.check_out_time",
      field: "check_out_time",
      label: "check_out_time",
      value: "11:00",
    },
  ]));

  assert.equal(result.decision.outcome, "reply");
  assert.equal(result.decision.escalation_required, false);
  assert.deepEqual(result.decision.evidence_ids, ["property.check_in_time"]);
  assert.match(result.decision.message_body, /15:00/);
});

test("arrival phrasing replies with inference", () => {
  const result = buildGroundedDecision(unknownEscalation("es"), {
    guest_message: "cuando puedo llegar?",
  }, catalogFromSource({
    source_type: "property_fact",
    source_id: "property_fact:check_in_time",
    evidence_id: "property.check_in_time",
    field: "check_in_time",
    label: "check_in_time",
    value: "15:00",
  }));

  assert.equal(result.decision.outcome, "reply");
  assert.equal(result.decision.detected_intents[0].status, "answered_with_inference");
  assert.match(result.decision.message_body, /15:00/);
});

test("departure phrasing replies with inference from checkout evidence", () => {
  const result = buildGroundedDecision(unknownEscalation("es"), {
    guest_message: "a qué hora puedo salir?",
  }, catalogFromSource({
    source_type: "property_fact",
    source_id: "property_fact:check_out_time",
    evidence_id: "property.check_out_time",
    field: "check_out_time",
    label: "check_out_time",
    value: "11:00",
  }));

  assert.equal(result.decision.outcome, "reply");
  assert.equal(result.decision.escalation_required, false);
  assert.deepEqual(result.decision.evidence_ids, ["property.check_out_time"]);
  assert.equal(result.decision.detected_intents[0].type, "check_out_time");
  assert.equal(result.decision.detected_intents[0].status, "answered_with_inference");
  assert.match(result.decision.message_body, /salida\/check-out/);
  assert.match(result.decision.message_body, /11:00/);
});

test("vague issue asks a clarification before escalating", () => {
  const result = buildGroundedDecision(unknownEscalation("es"), {
    guest_message: "no anda",
  }, []);

  assert.equal(result.decision.outcome, "ask_clarifying_question");
  assert.equal(result.decision.escalation_required, false);
  assert.equal(result.decision.detected_intents[0].type, "ambiguous_issue");
  assert.match(result.decision.message_body, /WiFi, puerta, agua, luz/);
  assert.equal(result.decision.audit.grounded_decision_builder.final_decision_strategy, "clarify_before_escalate");
  assert.equal(result.decision.audit.grounded_decision_builder.decision_scores.safety_score, 50);
});

test("medium confidence asks clarification instead of escalating", () => {
  const result = buildGroundedDecision(unknownEscalation("en"), {
    guest_message: "What are the building hours?",
  }, buildEvidenceCatalog([{
    toolName: "property_brain",
    result: [
      source({
        source_type: "knowledge_block",
        source_id: "knowledge_block:1",
        evidence_id: "guide.1",
        label: "Pool hours",
        value: "The pool is open from 9 to 18.",
        category: "building",
      }),
      source({
        source_type: "knowledge_block",
        source_id: "knowledge_block:2",
        evidence_id: "guide.2",
        label: "Gym hours",
        value: "The gym is open from 8 to 20.",
        category: "building",
      }),
    ],
  }]));

  const scores = result.decision.audit.grounded_decision_builder.decision_scores;

  assert.equal(result.decision.outcome, "ask_clarifying_question");
  assert.equal(result.decision.escalation_required, false);
  assert.ok(scores.answer_confidence >= 40);
  assert.ok(scores.evidence_relevance_score >= 40);
});

test("two clarification attempts without resolution leave escalation as last resort", () => {
  const result = buildGroundedDecision(unknownEscalation("es"), {
    guest_message: "no anda",
    conversation_history: [
      { sender: "ai", body: "¿Qué es lo que no está funcionando: WiFi, puerta, agua, luz u otra cosa?" },
      { sender: "ai", body: "¿Podés aclararme qué sigue sin funcionar exactamente?" },
    ],
  }, []);

  const trace = result.decision.audit.grounded_decision_builder;

  assert.equal(result.decision.outcome, "escalate");
  assert.equal(result.override, null);
  assert.equal(trace.clarification_attempts.count, 2);
  assert.equal(trace.grounded_decision_result.reason_if_null, "clarification_attempts_exhausted");
});

test("FAQ evidence answers simple reusable question", () => {
  const result = buildGroundedDecision(unknownEscalation("es"), {
    guest_message: "Cómo llego q pileta?",
  }, catalogFromSource({
    source_type: "faq",
    source_id: "faq:7",
    evidence_id: "faq.7",
    label: "Como bajo a la pileta?",
    field: "Como bajo a la pileta?",
    value: "Andá al -1 y después subí por la ventana.",
    category: "amenities",
  }));

  assert.equal(result.decision.outcome, "reply");
  assert.deepEqual(result.decision.evidence_ids, ["faq.7"]);
  assert.match(result.decision.message_body, /Andá al -1/);
});

test("guide or knowledge block evidence answers operational question", () => {
  const result = buildGroundedDecision(unknownEscalation("es"), {
    guest_message: "Dónde puedo tirar la basura?",
  }, catalogFromSource({
    source_type: "knowledge_block",
    source_id: "knowledge_block:12",
    evidence_id: "guide.12",
    label: "Basura del edificio",
    field: "Basura del edificio",
    value: "Los tachos están en planta baja al lado del ascensor.",
    category: "building",
  }));

  assert.equal(result.decision.outcome, "reply");
  assert.deepEqual(result.decision.evidence_ids, ["guide.12"]);
  assert.match(result.decision.message_body, /tachos/);
});

test("policy evidence that requires approval proposes a narrow escalation without promising", () => {
  const result = buildGroundedDecision(unknownEscalation("es"), {
    guest_message: "Puedo invitar visitas?",
  }, catalogFromSource({
    source_type: "policy",
    source_id: "policy:visitors",
    evidence_id: "policy.visitors",
    field: "visitors",
    label: "visitors",
    value: "approval_required",
  }));

  assert.equal(result.override?.reason, "approval_required");
  assert.equal(result.decision.outcome, "propose_action");
  assert.equal(result.decision.escalation_required, true);
  assert.deepEqual(result.decision.evidence_ids, ["policy.visitors"]);
  assert.match(result.decision.message_body, /requiere aprobación/);
  assert.doesNotMatch(result.decision.message_body, /aprobado|confirmado/i);
});

test("approved recommendation evidence answers recommendation request", () => {
  const result = buildGroundedDecision(unknownEscalation("es"), {
    guest_message: "Tenés un café cerca para recomendar?",
  }, catalogFromSource({
    source_type: "recommendation",
    source_id: "recommendation:3",
    evidence_id: "recommendation.3",
    label: "Café Roma",
    field: "Café Roma",
    value: "Buen café a dos cuadras.",
    category: "cafe",
    address: "Calle 1 123",
    google_maps_url: "https://maps.example/cafe",
  }));

  assert.equal(result.decision.outcome, "reply");
  assert.deepEqual(result.decision.evidence_ids, ["recommendation.3"]);
  assert.match(result.decision.message_body, /Café Roma/);
});

test("partial evidence asks for clarification", () => {
  const result = buildGroundedDecision(unknownEscalation("en"), {
    guest_message: "What are the building hours?",
  }, buildEvidenceCatalog([{
    toolName: "property_brain",
    result: [
      source({
        source_type: "knowledge_block",
        source_id: "knowledge_block:1",
        evidence_id: "guide.1",
        label: "Pool hours",
        value: "The pool is open from 9 to 18.",
        category: "building",
      }),
      source({
        source_type: "knowledge_block",
        source_id: "knowledge_block:2",
        evidence_id: "guide.2",
        label: "Gym hours",
        value: "The gym is open from 8 to 20.",
        category: "building",
      }),
    ],
  }]));

  assert.equal(result.override?.reason, "partial_evidence");
  assert.equal(result.decision.outcome, "ask_clarifying_question");
  assert.equal(result.decision.escalation_required, false);
  assert.deepEqual(result.decision.evidence_ids, ["guide.1", "guide.2"]);
});

test("no evidence leaves the escalation untouched", () => {
  const original = unknownEscalation("en");
  const result = buildGroundedDecision(original, {
    guest_message: "What color is the front door?",
  }, []);

  assert.equal(result.override, null);
  assert.equal(result.decision.outcome, "escalate");
  assert.equal(result.decision.audit.grounded_decision_builder.evidence_catalog_size, 0);
  assert.equal(result.decision.audit.grounded_decision_builder.grounded_decision_result.reason_if_null, "no_ranked_candidates");
  assert.equal(result.decision.audit.grounded_decision_builder.final_decision_source.model, true);
});

test("sufficient evidence never remains unknown and evidence ids are present", () => {
  const result = buildGroundedDecision(unknownEscalation("en"), {
    guest_message: "Can you send the address?",
  }, catalogFromSource({
    source_type: "property_fact",
    source_id: "property_fact:address",
    evidence_id: "property.address",
    field: "address",
    label: "address",
    value: "123 Test Street",
  }));

  assert.equal(result.decision.outcome, "reply");
  assert.notEqual(result.decision.detected_intents[0].type, "unknown");
  assert.deepEqual(result.decision.evidence_ids, ["property.address"]);
  assert.ok(result.decision.audit.grounded_decision_builder.decision_scores.answer_confidence >= 75);
  assert.ok(result.decision.audit.grounded_decision_builder.decision_scores.evidence_relevance_score >= 75);
  assert.ok(result.decision.audit.grounded_decision_builder.decision_scores.safety_score >= 75);
});

test("custom high threshold can move medium evidence to clarification", () => {
  const result = buildGroundedDecision(unknownEscalation("es"), {
    guest_message: "a que hora puedo entrar al depto?",
    decision_settings: {
      high_score_threshold: 95,
      medium_score_threshold: 40,
      safety_score_threshold: 75,
      max_clarification_attempts: 2,
    },
  }, catalogFromSource({
    source_type: "property_fact",
    source_id: "property_fact:check_in_time",
    evidence_id: "property.check_in_time",
    field: "check_in_time",
    label: "check_in_time",
    value: "15:00",
  }));

  const audit = result.decision.audit.grounded_decision_builder;
  assert.equal(result.decision.outcome, "ask_clarifying_question");
  assert.equal(audit.score_thresholds.high_score_threshold, 95);
  assert.equal(audit.grounded_decision_result.override_type, "partial_evidence");
});

test("custom max clarification attempts controls when ambiguous cases escalate", () => {
  const result = buildGroundedDecision(unknownEscalation("es"), {
    guest_message: "a que hora puedo ir?",
    decision_settings: {
      high_score_threshold: 75,
      medium_score_threshold: 40,
      safety_score_threshold: 75,
      max_clarification_attempts: 1,
    },
    clarification_attempts: {
      ambiguous_request: 1,
      ambiguous_time: 1,
      total: 1,
    },
  }, catalogFromSources([
    {
      source_type: "property_fact",
      source_id: "property_fact:check_in_time",
      evidence_id: "property.check_in_time",
      field: "check_in_time",
      label: "check_in_time",
      value: "15:00",
    },
    {
      source_type: "property_fact",
      source_id: "property_fact:check_out_time",
      evidence_id: "property.check_out_time",
      field: "check_out_time",
      label: "check_out_time",
      value: "11:00",
    },
  ]));

  const audit = result.decision.audit.grounded_decision_builder;
  assert.equal(result.decision.outcome, "escalate");
  assert.equal(audit.clarification_attempts.max, 1);
  assert.equal(audit.grounded_decision_result.reason_if_null, "clarification_attempts_exhausted");
});

function unknownEscalation(language: string) {
  return {
    outcome: "escalate",
    decision: "escalate",
    language,
    message_body: "Lo estoy consultando con el anfitrión.",
    detected_intents: [{ type: "unknown", status: "escalated" }],
    evidence_ids: [],
    escalation_required: true,
    escalation: {
      required: true,
      reason_code: "unknown",
      summary_for_host: "No se pudo responder.",
    },
    confidence: 0.3,
    safety_flags: ["fallback"],
  };
}

function catalogFromSource(data: Record<string, unknown>) {
  return buildEvidenceCatalog([{ toolName: "property_brain", result: source(data) }]);
}

function catalogFromSources(items: Array<Record<string, unknown>>) {
  return buildEvidenceCatalog([{ toolName: "property_brain", result: items.map(source) }]);
}

function source(data: Record<string, unknown>) {
  return {
    type: data.source_type,
    title: data.label,
    content: data.value,
    excerpt: data.value,
    ...data,
  };
}
