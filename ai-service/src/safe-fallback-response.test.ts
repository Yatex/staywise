import assert from "node:assert/strict";
import test from "node:test";
import { ensureSafeFallbackResponse, safeFallbackResponseFor } from "./safe-fallback-response.js";

test("safe fallback response follows the detected guest language", () => {
  assert.match(safeFallbackResponseFor("es"), /información confirmada/);
  assert.match(safeFallbackResponseFor("fr"), /information confirmée/);
  assert.match(safeFallbackResponseFor("en"), /information confirmed/);
});

test("every decision receives a safe fallback when the model omitted it", () => {
  const decision = ensureSafeFallbackResponse({
    outcome: "reply",
    language: "fr",
    message_body: "Le check-in est à 15:00.",
  });

  assert.match(String(decision.safe_fallback_response), /information confirmée/);
});

test("existing safe fallback is sanitized and preserved in its language", () => {
  const decision = ensureSafeFallbackResponse({
    outcome: "reply",
    language: "es",
    safe_fallback_response: "Necesito revisar esa información. (Fuente: property.check_in_time)",
  });

  assert.equal(decision.safe_fallback_response, "Necesito revisar esa información.");
});
