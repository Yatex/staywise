import assert from "node:assert/strict";
import test from "node:test";
import {
  buildEvidenceCatalog,
  canonicalEvidenceId,
  shouldRetryGroundedDecision,
} from "./evidence-catalog.js";

test("check-in evidence aliases are normalized to the Rails evidence id", () => {
  for (const evidenceId of [
    "property_check_in_time",
    "property.check_in_time",
    "property_fact:check_in_time",
  ]) {
    assert.equal(canonicalEvidenceId(evidenceId), "property.check_in_time");
  }
});

test("tool results produce a grounded check-in evidence catalog", () => {
  const catalog = buildEvidenceCatalog([
    {
      toolName: "stay_facts",
      result: [{
        source_id: "property_fact:check_in_time",
        evidence_id: "property.check_in_time",
        field: "check_in_time",
        value: "15:00",
      }],
    },
    {
      toolName: "guest_context",
      result: {
        evidence: [{ evidence_id: "property_check_in_time", field: "check_in_time", value: "15:00" }],
      },
    },
  ]);

  assert.equal(catalog.length, 1);
  assert.deepEqual(catalog[0], {
    evidence_id: "property.check_in_time",
    raw_id: "property.check_in_time",
    field: "check_in_time",
    value: "15:00",
    tool_name: "stay_facts",
  });
});

test("unknown escalation without citations is reviewed when tool evidence exists", () => {
  const catalog = [{
    evidence_id: "property.check_in_time",
    raw_id: "property.check_in_time",
    field: "check_in_time",
    value: "15:00",
    tool_name: "stay_facts",
  }];

  assert.equal(shouldRetryGroundedDecision({
    outcome: "escalate",
    detected_intents: [{ type: "unknown", status: "escalated" }],
    evidence_ids: [],
  }, catalog), true);
  assert.equal(shouldRetryGroundedDecision({
    outcome: "reply",
    detected_intents: [{ type: "check_in_time", status: "answered" }],
    evidence_ids: ["property.check_in_time"],
  }, catalog), false);
});
