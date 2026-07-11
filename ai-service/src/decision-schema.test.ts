import assert from "node:assert/strict";
import test from "node:test";
import { DecisionSchema, recoverDecisionFromRawText, toPublicDecision } from "./decision-schema.js";

const reply = {
  action: "reply",
  owner_task_kind: null,
  language: "es",
  message: "La red Wi-Fi es Pepe.",
  task_summary: null,
  answer_confidence: 96,
  evidence_ids: ["property.wifi_name"],
  attachments: [],
};

test("AylaDecision parses the single final reply contract", () => {
  const parsed = DecisionSchema.parse(reply);
  assert.equal(parsed.outcome, "reply");
  assert.equal(parsed.message_body, reply.message);
  assert.equal(parsed.answer_confidence, 96);
  assert.deepEqual(parsed.evidence_ids, ["property.wifi_name"]);
});

test("AylaDecision parses clarify without an owner task", () => {
  const parsed = DecisionSchema.parse({ ...reply, action: "clarify", message: "¿Cuántas mantas necesitás?", answer_confidence: 70, evidence_ids: [] });
  assert.equal(parsed.outcome, "ask_clarifying_question");
  assert.equal(parsed.owner_task_kind, null);
});

test("AylaDecision requires an explicit owner task kind", () => {
  assert.equal(DecisionSchema.safeParse({ ...reply, action: "create_owner_task", task_summary: "Dos mantas" }).success, false);
  const parsed = DecisionSchema.parse({ ...reply, action: "create_owner_task", owner_task_kind: "request", task_summary: "Dos mantas", evidence_ids: [] });
  assert.equal(parsed.outcome, "propose_action");
  assert.equal(parsed.owner_task_kind, "request");
});

test("AylaDecision accepts directly useful attachments", () => {
  const parsed = DecisionSchema.parse({ ...reply, attachments: [{ type: "video", evidence_id: "guide.12" }] });
  assert.deepEqual(parsed.attachments, [{ type: "video", evidence_id: "guide.12" }]);
});

test("AylaDecision rejects unknown actions and attachment types", () => {
  assert.equal(DecisionSchema.safeParse({ ...reply, action: "escalate" }).success, false);
  assert.equal(DecisionSchema.safeParse({ ...reply, attachments: [{ type: "audio", evidence_id: "guide.12" }] }).success, false);
});

test("raw JSON recovery uses the same contract", () => {
  const recovered = recoverDecisionFromRawText(`\`\`\`json\n${JSON.stringify(reply)}\n\`\`\``);
  assert.equal(recovered.ok, true);
});

test("public projection removes candidate and safe fallback fields", () => {
  const projected = toPublicDecision({ ...DecisionSchema.parse(reply), safe_fallback_response: "legacy", candidate_response: "legacy" });
  assert.equal("safe_fallback_response" in projected, false);
  assert.equal("candidate_response" in projected, false);
  assert.equal(projected.action, "reply");
});
