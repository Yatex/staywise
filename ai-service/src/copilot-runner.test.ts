import assert from "node:assert/strict";
import test from "node:test";
import { runCopilot } from "./copilot-runner.js";

const model = {} as any;

function validResponse(overrides: Record<string, unknown> = {}) {
  return {
    detected_language: "en",
    guest_question_es: "Pregunta cómo abrir la cerradura.",
    answer_summary_es: "Debe usar el código documentado.",
    guest_reply: "Enter 4821# and see https://example.test/lock?v=2&lang=en",
    confidence: 95,
    missing_information: false,
    clarifying_question_es: null,
    clarifying_question_guest: null,
    evidence_refs: ["property_knowledge.12"],
    ...overrides,
  };
}

function payload(overrides: Record<string, unknown> = {}) {
  return {
    property: { id: 7, name: "Palermo" },
    guest_message: "The lock does not work",
    host_context: null,
    thread_history: [],
    ...overrides,
  } as any;
}

test("retrieves only the property tool selected by the model", async () => {
  const calls: Array<[string, Record<string, unknown>]> = [];
  const generate = async (options: any) => {
    await options.tools.property_brain.execute({ query: "lock troubleshooting", limit: 6 });
    return { experimental_output: validResponse(), usage: {}, totalUsage: {}, steps: [{ toolCalls: [{}] }] };
  };

  const result = await runCopilot({
    model,
    payload: payload(),
    callTool: async (name, input) => { calls.push([name, input]); return { evidence: [] }; },
    generate: generate as any,
  });

  assert.equal(result.output.detected_language, "en");
  assert.deepEqual(calls.map(([name]) => name), ["property_brain"]);
  assert.equal("property_id" in calls[0][1], false, "property scope must come from the signed Rails context");
  assert.equal("account_id" in calls[0][1], false);
});

test("drops evidence references that were not returned by scoped tools", async () => {
  const generate = async (options: any) => {
    await options.tools.property_brain.execute({ query: "check-in", limit: 6 });
    return {
      experimental_output: validResponse({
        evidence_refs: ["property.check_in_time", "guide.from-another-property"],
      }),
      usage: {}, totalUsage: {}, steps: [],
    };
  };

  const result = await runCopilot({
    model,
    payload: payload(),
    callTool: async () => ({ evidence: [{ evidence_id: "property.check_in_time", value: "15:00" }] }),
    generate: generate as any,
  });

  assert.deepEqual(result.output.evidence_refs, ["property.check_in_time"]);
});

test("supports English, Portuguese, and Spanish while keeping host explanations in Spanish", async () => {
  for (const [language, reply] of [["en", "Use the heater."], ["pt", "Use o aquecedor."], ["es", "Usá la calefacción."]]) {
    const generate = async () => ({
      experimental_output: validResponse({ detected_language: language, guest_reply: reply }),
      usage: {}, totalUsage: {}, steps: [],
    });
    const result = await runCopilot({ model, payload: payload(), callTool: async () => ({}), generate: generate as any });
    assert.equal(result.output.detected_language, language);
    assert.equal(result.output.guest_reply, reply);
    assert.match(result.output.guest_question_es, /Pregunta/);
  }
});

test("returns bilingual clarification for missing or conflicting information", async () => {
  const generate = async () => ({
    experimental_output: validResponse({
      guest_reply: null,
      confidence: 18,
      missing_information: true,
      clarifying_question_es: "Confirmá cuál de las dos cerraduras está usando.",
      clarifying_question_guest: "Which of the two locks are you using?",
      evidence_refs: ["property_knowledge.1", "property_knowledge.2"],
    }),
    usage: {}, totalUsage: {}, steps: [],
  });
  const result = await runCopilot({ model, payload: payload(), callTool: async () => ({}), generate: generate as any });
  assert.equal(result.output.missing_information, true);
  assert.match(result.output.clarifying_question_es!, /Confirmá/);
  assert.match(result.output.clarifying_question_guest!, /Which/);
});

test("preserves access codes, hash sequences, and complete URLs", async () => {
  const exact = "Enter 4821# and open https://example.test/lock?v=2&lang=en";
  const generate = async () => ({ experimental_output: validResponse({ guest_reply: exact }), usage: {}, totalUsage: {}, steps: [] });
  const result = await runCopilot({ model, payload: payload(), callTool: async () => ({}), generate: generate as any });
  assert.equal(result.output.guest_reply, exact);
});

test("propagates a tool timeout without manufacturing a response", async () => {
  const generate = async (options: any) => {
    await options.tools.sensitive_access_info.execute({ query: "door code" });
    throw new Error("tool_timeout");
  };
  await assert.rejects(
    runCopilot({ model, payload: payload(), callTool: async () => { throw new Error("tool_timeout"); }, generate: generate as any }),
    /tool_timeout/,
  );
});

test("propagates an OpenAI timeout", async () => {
  const generate = async () => { throw new Error("openai_timeout"); };
  await assert.rejects(runCopilot({ model, payload: payload(), callTool: async () => ({}), generate: generate as any }), /openai_timeout/);
});

test("rejects malformed structured output", async () => {
  const generate = async () => ({ experimental_output: { detected_language: "en" }, usage: {}, totalUsage: {}, steps: [] });
  await assert.rejects(runCopilot({ model, payload: payload(), callTool: async () => ({}), generate: generate as any }));
});

test("can report missing information without calling a tool", async () => {
  let calls = 0;
  const generate = async () => ({
    experimental_output: validResponse({
      guest_reply: null,
      confidence: 5,
      missing_information: true,
      clarifying_question_es: "Pedile al huésped una foto del equipo.",
      clarifying_question_guest: "Could you send a photo of the device?",
      evidence_refs: [],
    }),
    usage: {}, totalUsage: {}, steps: [],
  });
  const result = await runCopilot({ model, payload: payload(), callTool: async () => { calls += 1; return {}; }, generate: generate as any });
  assert.equal(calls, 0);
  assert.equal(result.output.missing_information, true);
});

test("passes only the last 12 messages for thread continuity", async () => {
  let prompt: any;
  const history = Array.from({ length: 15 }, (_, index) => ({ role: index % 2 ? "assistant" : "user", content: `turn-${index}` }));
  const generate = async (options: any) => {
    prompt = JSON.parse(options.prompt);
    return { experimental_output: validResponse(), usage: {}, totalUsage: {}, steps: [] };
  };
  await runCopilot({ model, payload: payload({ thread_history: history }), callTool: async () => ({}), generate: generate as any });
  assert.equal(prompt.thread_history.length, 12);
  assert.equal(prompt.thread_history[0].content, "turn-3");
  assert.equal(prompt.thread_history[11].content, "turn-14");
});
