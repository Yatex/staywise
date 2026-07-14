import assert from "node:assert/strict";
import test from "node:test";
import { DECISION_SYSTEM_PROMPT, GROUNDED_REVIEW_SYSTEM_PROMPT } from "./decision-system-prompt.js";
import { classifyConversationalOnly, shouldBypassModelForConversational } from "./conversational-classifier.js";

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

test("decision prompts require one final action contract", () => {
  assert.match(DECISION_SYSTEM_PROMPT, /exactly one final action/i);
  assert.match(DECISION_SYSTEM_PROMPT, /answer_confidence/i);
  assert.doesNotMatch(DECISION_SYSTEM_PROMPT, /Always provide safe_fallback_response/i);
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

test("decision prompts troubleshoot property problems before creating inquiries", () => {
  for (const prompt of [DECISION_SYSTEM_PROMPT, GROUNDED_REVIEW_SYSTEM_PROMPT]) {
    assert.match(prompt, /Troubleshoot reported problems before escalating/i);
    assert.match(prompt, /instructions, manuals, videos, FAQs, guides, knowledge blocks/i);
    assert.match(prompt, /wait for the guest to report whether they worked/i);
    assert.match(prompt, /Do not create an owner task in the same turn/i);
    assert.match(prompt, /confirms that the problem is resolved.*never create an inquiry/i);
    assert.match(prompt, /followed the instructions and the problem continues/i);
    assert.match(prompt, /new problem report by itself is not confirmation/i);
  }
});

test("decision prompt uses contextual no_action without hiding new needs", () => {
  assert.match(DECISION_SYSTEM_PROMPT, /latest message and the conversation history/i);
  assert.match(DECISION_SYSTEM_PROMPT, /action no_action with message=null/i);
  assert.match(DECISION_SYSTEM_PROMPT, /also contains a new request, an unresolved problem/i);
  assert.match(DECISION_SYSTEM_PROMPT, /information answering Ayla's previous clarification/i);
  assert.match(DECISION_SYSTEM_PROMPT, /absence of a new need is not missing property knowledge/i);
  assert.match(DECISION_SYSTEM_PROMPT, /A short answer such as 'yes', 'for walking', or 'names only'/i);
});

test("decision prompt forbids unverified future searches and redundant clarification", () => {
  assert.match(DECISION_SYSTEM_PROMPT, /Never offer or promise to search, look up, investigate/i);
  assert.match(DECISION_SYSTEM_PROMPT, /use it directly instead of asking permission/i);
  assert.match(DECISION_SYSTEM_PROMPT, /ask only for that missing input/i);
  assert.match(DECISION_SYSTEM_PROMPT, /never repeat a question already answered/i);
  assert.match(DECISION_SYSTEM_PROMPT, /no suitable tool or sufficient knowledge exists/i);
});

test("only unequivocal greetings bypass contextual model interpretation", () => {
  assert.equal(shouldBypassModelForConversational(classifyConversationalOnly("Hola")), true);
  assert.equal(shouldBypassModelForConversational(classifyConversationalOnly("Gracias")), false);
  assert.equal(shouldBypassModelForConversational(classifyConversationalOnly("Perfecto")), false);
  assert.equal(shouldBypassModelForConversational(classifyConversationalOnly("Súper")), false);
  assert.equal(shouldBypassModelForConversational(classifyConversationalOnly("Sí")), false);
  assert.equal(shouldBypassModelForConversational(classifyConversationalOnly("Perfecto, necesito otra manta")), false);
});
