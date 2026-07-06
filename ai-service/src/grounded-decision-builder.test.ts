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
  assert.equal(result.decision, original);
  assert.equal(result.decision.outcome, "escalate");
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

function source(data: Record<string, unknown>) {
  return {
    type: data.source_type,
    title: data.label,
    content: data.value,
    excerpt: data.value,
    ...data,
  };
}
