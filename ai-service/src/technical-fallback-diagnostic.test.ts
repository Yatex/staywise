import assert from "node:assert/strict";
import test from "node:test";
import { classifyTechnicalFallback } from "./technical-fallback-diagnostic.js";

test("classifies a tool timeout with the affected tool and duration", () => {
  const diagnostic = classifyTechnicalFallback(
    new Error("tool failed"),
    [{ tool_name: "property_brain", error: "tool_timeout", latency_ms: 5_000 }],
    [],
  );

  assert.equal(diagnostic.type, "TOOL_TIMEOUT");
  assert.equal(diagnostic.tool, "property_brain");
  assert.equal(diagnostic.tool_duration_ms, 5_000);
  assert.equal(diagnostic.tools_executed, 1);
});

test("classifies a model timeout separately from a tool timeout", () => {
  const diagnostic = classifyTechnicalFallback(
    Object.assign(new Error("request timed out"), { name: "TimeoutError" }),
    [],
    [{ error_name: "TimeoutError", error_message: "model timed out" }],
  );

  assert.equal(diagnostic.type, "OPENAI_TIMEOUT");
  assert.equal(diagnostic.provider, "openai");
  assert.equal(diagnostic.tools_executed, 0);
});

test("classifies unexpected errors without exposing a stack", () => {
  const diagnostic = classifyTechnicalFallback(new Error("unexpected"), [], []);

  assert.equal(diagnostic.type, "INTERNAL_EXCEPTION");
  assert.equal(diagnostic.exception_message, "unexpected");
  assert.equal("backtrace" in diagnostic, false);
  assert.equal("stack" in diagnostic, false);
});
