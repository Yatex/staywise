import assert from "node:assert/strict";
import test from "node:test";
import { DECISION_SYSTEM_PROMPT, GROUNDED_REVIEW_SYSTEM_PROMPT } from "./decision-system-prompt.js";

test("decision prompts forbid source metadata in guest-facing replies", () => {
  for (const prompt of [DECISION_SYSTEM_PROMPT, GROUNDED_REVIEW_SYSTEM_PROMPT]) {
    assert.match(prompt, /Guest-facing message_body must be completely natural/i);
    assert.match(prompt, /Never include phrases like Source, Fuente, Источник/i);
    assert.match(prompt, /Keep evidence references only in structured fields/i);
    assert.match(prompt, /Do not concatenate them into guest-visible text/i);
  }
});

test("decision prompt still requires structured evidence for audit", () => {
  assert.match(DECISION_SYSTEM_PROMPT, /Use evidence_ids for evidence_id values/);
  assert.match(DECISION_SYSTEM_PROMPT, /used_source_ids for source id values/);
});

test("decision prompts require a localized neutral safe fallback", () => {
  assert.match(DECISION_SYSTEM_PROMPT, /Always provide safe_fallback_response in the same language as the latest guest message/i);
  assert.match(DECISION_SYSTEM_PROMPT, /must not claim that the host was contacted/i);
  assert.match(GROUNDED_REVIEW_SYSTEM_PROMPT, /Always provide safe_fallback_response in the latest guest message's language/i);
});

test("decision prompt classifies owner-managed requests as guest requests", () => {
  assert.match(DECISION_SYSTEM_PROMPT, /item, service, delivery, food, drink, extra bed/i);
  assert.match(DECISION_SYSTEM_PROMPT, /classify it as a guest request/i);
  assert.match(DECISION_SYSTEM_PROMPT, /request_food_or_drink/);
  assert.match(DECISION_SYSTEM_PROMPT, /request_extra_bed/);
  assert.match(DECISION_SYSTEM_PROMPT, /confirm receipt only/i);
});

test("decision prompts follow respond-first clarification rules", () => {
  for (const prompt of [DECISION_SYSTEM_PROMPT, GROUNDED_REVIEW_SYSTEM_PROMPT]) {
    assert.match(prompt, /Respond first, clarify only when necessary/i);
    assert.match(prompt, /Only ask a clarification when the guest's answer would materially change/i);
    assert.match(prompt, /Never offer maps, Google Maps routes, navigation/i);
    assert.match(prompt, /Never promise future actions/i);
  }
});
