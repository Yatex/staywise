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

test("sensitive WiFi evidence aliases are normalized to property evidence ids", () => {
  assert.equal(canonicalEvidenceId("sensitive_wifi_name"), "property.wifi_name");
  assert.equal(canonicalEvidenceId("sensitive_wifi_password"), "property.wifi_password");
  assert.equal(canonicalEvidenceId("property_fact:wifi_name"), "property.wifi_name");
  assert.equal(canonicalEvidenceId("property_fact:wifi_password"), "property.wifi_password");
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
    label: "check_in_time",
    source_type: null,
    category: null,
    value: "15:00",
    text: "check_in_time check_in_time 15:00",
    sensitivity: null,
    authorization_required: false,
    authorized: true,
    metadata: {},
    tool_name: "stay_facts",
  });
});

test("tool evidence preserves a complete relevant video URL and long access instructions", () => {
  const videoUrl = "https://www.youtube.com/watch?v=IngresoABC123&t=42s#paso-2";
  const instructions = "Subí al piso 1, puerta E. Tocá el panel, ingresá el código 4826 y después presioná #.";
  const catalog = buildEvidenceCatalog([{
    toolName: "property_brain",
    result: [{
      evidence_id: "guide.72",
      source_type: "knowledge_block",
      title: "Ingreso con cerradura electrónica",
      content: instructions,
      youtube_url: videoUrl,
    }],
  }]);

  assert.equal(catalog.length, 1);
  assert.equal(catalog[0].value, instructions);
  assert.equal(catalog[0].metadata.youtube_url, videoUrl);
  assert.match(catalog[0].text, /4826/);
  assert.match(catalog[0].text, /presioná #/);
  assert.match(catalog[0].text, /watch\?v=IngresoABC123&t=42s#paso-2/);
});

test("unknown escalation without citations is reviewed when tool evidence exists", () => {
  const catalog = [{
    evidence_id: "property.check_in_time",
    raw_id: "property.check_in_time",
    field: "check_in_time",
    label: "check_in_time",
    source_type: "property_fact",
    category: null,
    value: "15:00",
    text: "check_in_time check_in_time property_fact 15:00",
    sensitivity: null,
    authorization_required: false,
    authorized: true,
    metadata: {},
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
