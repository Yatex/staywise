import assert from "node:assert/strict";
import test from "node:test";
import { DecisionSchema, recoverDecisionFromRawText } from "./decision-schema.js";

const checkInReply = {
  outcome: "reply",
  language: "es",
  message_body: "El check-in es a las 15:00.",
  intent_summary: "Consulta sobre hora de check-in - respondida",
  detected_intents: [{ type: "check_in_time", status: "answered" }],
  used_source_ids: ["property_fact:check_in_time"],
  evidence_ids: ["property.check_in_time"],
  required_capabilities: [],
  proposed_action: null,
  escalation: {
    reason_code: null,
    summary_for_host: null,
  },
  escalation_required: false,
  escalation_reason: null,
  sensitive_info_used: false,
  missing_information: [],
  safety_flags: [],
  confidence: 0.9,
};

test("AylaDecision parses a grounded check-in reply", () => {
  const parsed = DecisionSchema.parse(checkInReply);

  assert.equal(parsed.outcome, "reply");
  assert.equal(parsed.message_body, "El check-in es a las 15:00.");
  assert.deepEqual(parsed.detected_intents, [{ type: "check_in_time", status: "answered" }]);
  assert.deepEqual(parsed.evidence_ids, ["property.check_in_time"]);
});

test("AylaDecision permits null contract fields and normalizes escalation.required", () => {
  const parsed = DecisionSchema.parse(checkInReply);

  assert.equal(parsed.proposed_action, null);
  assert.equal(parsed.escalation.required, false);
  assert.equal(parsed.escalation.reason_code, null);
  assert.equal(parsed.escalation.summary_for_host, null);
  assert.equal(parsed.escalation_reason, null);
});

test("AylaDecision accepts check_in_time answered intent", () => {
  const parsed = DecisionSchema.parse(checkInReply);

  assert.equal(parsed.detected_intents[0].type, "check_in_time");
  assert.equal(parsed.detected_intents[0].status, "answered");
});

test("AylaDecision accepts answered_with_inference intent status", () => {
  const parsed = DecisionSchema.parse({
    ...checkInReply,
    detected_intents: [{ type: "check_in_time", status: "answered_with_inference" }],
  });

  assert.equal(parsed.detected_intents[0].status, "answered_with_inference");
});

test("AylaDecision can normalize response_text into message_body", () => {
  const parsed = DecisionSchema.parse({
    ...checkInReply,
    message_body: undefined,
    response_text: "El check-in es a las 15:00.",
  });

  assert.equal(parsed.message_body, "El check-in es a las 15:00.");
});

test("AylaDecision sanitizes internal metadata from guest-facing message_body", () => {
  const parsed = DecisionSchema.parse({
    ...checkInReply,
    message_body: "Le check-in est à 15:00. (Source : property.check_in_time)",
  });

  assert.equal(parsed.message_body, "Le check-in est à 15:00.");
  assert.deepEqual(parsed.evidence_ids, ["property.check_in_time"]);
  assert.deepEqual(parsed.used_source_ids, ["property_fact:check_in_time"]);
});

test("AylaDecision sanitizes normalized response_text without losing evidence", () => {
  const parsed = DecisionSchema.parse({
    ...checkInReply,
    message_body: undefined,
    response_text: "El check-in es a las 15:00. source_id: property_fact:check_in_time",
  });

  assert.equal(parsed.message_body, "El check-in es a las 15:00.");
  assert.deepEqual(parsed.evidence_ids, ["property.check_in_time"]);
  assert.deepEqual(parsed.used_source_ids, ["property_fact:check_in_time"]);
});

test("recoverDecisionFromRawText uses valid JSON instead of forcing fallback", () => {
  const recovered = recoverDecisionFromRawText(JSON.stringify(checkInReply));

  assert.equal(recovered.ok, true);
  assert.equal(recovered.value.outcome, "reply");
  assert.equal(recovered.value.escalation.required, false);
});

test("recoverDecisionFromRawText rejects invalid JSON or schema mismatches", () => {
  assert.equal(recoverDecisionFromRawText("not json").ok, false);
  assert.equal(recoverDecisionFromRawText(JSON.stringify({ outcome: "reply" })).ok, false);
});
