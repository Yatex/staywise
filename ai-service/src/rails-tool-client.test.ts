import assert from "node:assert/strict";
import test from "node:test";
import { callRailsTool } from "./rails-tool-client.js";

test("mandatory Rails tools always send the shared Bearer token", async () => {
  const requests: Array<{ url: string; init: RequestInit }> = [];
  const fetchImpl = async (url: URL | RequestInfo, init?: RequestInit) => {
    requests.push({ url: url.toString(), init: init || {} });
    return {
      ok: true,
      status: 200,
      text: async () => JSON.stringify({ evidence: [{ evidence_id: "property.check_in_time" }] }),
    } as Response;
  };
  const endpoint = {
    base_url: "https://aylamanager.example",
    decision_context_id: "signed-context",
  };

  for (const toolName of ["guest_context", "stay_facts", "property_brain"]) {
    await callRailsTool(endpoint, toolName, { query: "check-in?" }, { fetchImpl, token: "shared-token" });
  }

  assert.equal(requests.length, 3);
  assert.deepEqual(requests.map((request) => request.url), [
    "https://aylamanager.example/internal/ai/tools/guest_context",
    "https://aylamanager.example/internal/ai/tools/stay_facts",
    "https://aylamanager.example/internal/ai/tools/property_brain",
  ]);
  for (const request of requests) {
    assert.equal(request.init.method, "POST");
    assert.deepEqual(request.init.headers, {
      Authorization: "Bearer shared-token",
      "Content-Type": "application/json",
    });
    assert.equal(JSON.parse(String(request.init.body)).decision_context_id, "signed-context");
  }
});

test("missing AI_SERVICE_TOKEN fails before making a Rails tool request", async () => {
  let fetchCalled = false;
  const fetchImpl = async () => {
    fetchCalled = true;
    throw new Error("fetch should not be called");
  };

  await assert.rejects(
    callRailsTool(
      { base_url: "https://aylamanager.example", decision_context_id: "signed-context" },
      "guest_context",
      {},
      { fetchImpl, token: "" },
    ),
    /AI_SERVICE_TOKEN is required/,
  );
  assert.equal(fetchCalled, false);
});
