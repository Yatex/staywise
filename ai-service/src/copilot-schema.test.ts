import assert from "node:assert/strict";
import test from "node:test";
import { CopilotResponseSchema, COPILOT_SYSTEM_PROMPT } from "./copilot-schema.js";

test("copilot contract accepts a grounded multilingual reply", () => {
  const parsed = CopilotResponseSchema.parse({
    detected_language: "en",
    guest_question_es: "Pregunta cómo encender la calefacción.",
    answer_summary_es: "Debe usar el control de la pared.",
    guest_reply: "Use the wall control and select HEAT.",
    confidence: 92,
    missing_information: false,
    clarifying_question_es: null,
    clarifying_question_guest: null,
    evidence_refs: ["guide.1"],
  });
  assert.equal(parsed.detected_language, "en");
});

test("copilot contract requires a clarification when information is missing", () => {
  const result = CopilotResponseSchema.safeParse({
    detected_language: "pt",
    guest_question_es: "Pregunta por el estacionamiento.",
    answer_summary_es: "No hay datos suficientes.",
    guest_reply: null,
    confidence: 20,
    missing_information: true,
    clarifying_question_es: null,
    clarifying_question_guest: null,
    evidence_refs: [],
  });
  assert.equal(result.success, false);
});

test("copilot contract rejects arbitrary actions and effect instructions", () => {
  const result = CopilotResponseSchema.safeParse({
    detected_language: "en",
    guest_question_es: "Pregunta cómo entrar.",
    answer_summary_es: "Debe usar las instrucciones de acceso.",
    guest_reply: "Use the access instructions.",
    confidence: 90,
    missing_information: false,
    clarifying_question_es: null,
    clarifying_question_guest: null,
    evidence_refs: ["guide.1"],
    action: "send_whatsapp",
    effects: [{ type: "create_owner_task" }],
  });

  assert.equal(result.success, false);
});

test("copilot prompt preserves operational values and forbids side effects", () => {
  assert.match(COPILOT_SYSTEM_PROMPT, /Preserve relevant URLs/);
  assert.match(COPILOT_SYSTEM_PROMPT, /never create tasks, alerts, notifications/i);
  assert.match(COPILOT_SYSTEM_PROMPT, /guest_reply must be the exact ready-to-copy response in that language/);
  assert.match(COPILOT_SYSTEM_PROMPT, /Call only the tools needed/);
  assert.match(COPILOT_SYSTEM_PROMPT, /Never claim that something was sent, changed, booked, approved, cancelled, fixed, or performed/);
  assert.match(COPILOT_SYSTEM_PROMPT, /Never invent WiFi details, codes, addresses, phones, schedules, policies, prices, access instructions, availability, or rules/);
});
