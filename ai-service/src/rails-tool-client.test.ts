import assert from "node:assert/strict";
import test from "node:test";
import {
  callRailsTool,
  resolveRailsToolEndpoint,
  validateRailsToolClientBootConfig,
} from "./rails-tool-client.js";

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

  for (const toolName of ["guest_context", "stay_facts", "property_brain", "escalation_draft"]) {
    await callRailsTool(endpoint, toolName, { query: "check-in?" }, {
      fetchImpl,
      token: "shared-token",
      environment: "production",
    });
  }

  assert.equal(requests.length, 4);
  assert.deepEqual(requests.map((request) => request.url), [
    "https://aylamanager.example/internal/ai/tools/guest_context",
    "https://aylamanager.example/internal/ai/tools/stay_facts",
    "https://aylamanager.example/internal/ai/tools/property_brain",
    "https://aylamanager.example/internal/ai/tools/escalation_draft",
  ]);
  for (const request of requests) {
    assert.equal(request.init.method, "POST");
    assert.equal(request.init.redirect, "error");
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

test("public HTTP Rails tool origins fail before fetch in production", async () => {
  let fetchCalled = false;
  const fetchImpl = async () => {
    fetchCalled = true;
    throw new Error("fetch should not be called");
  };

  await assert.rejects(
    callRailsTool(
      { base_url: "http://aylamanager.com", decision_context_id: "signed-context" },
      "stay_facts",
      {},
      { fetchImpl, token: "shared-token", environment: "production" },
    ),
    /must use HTTPS or a private Render HTTP address.*http:\/\/aylamanager\.com/,
  );
  assert.equal(fetchCalled, false);
});

test("private Render HTTP origin with an explicit port is allowed in production", async () => {
  let requestedUrl = "";
  const fetchImpl = async (url: URL | RequestInfo) => {
    requestedUrl = url.toString();
    return {
      ok: true,
      status: 200,
      text: async () => JSON.stringify({ evidence: [{ evidence_id: "property.check_in_time" }] }),
    } as Response;
  };

  const result = await callRailsTool(
    { base_url: "http://staywise-ji62:10000", decision_context_id: "signed-context" },
    "stay_facts",
    { requested_fields: ["check_in_time"] },
    { fetchImpl, token: "shared-token", environment: "production" },
  );

  assert.equal(requestedUrl, "http://staywise-ji62:10000/internal/ai/tools/stay_facts");
  assert.equal(result.evidence[0].evidence_id, "property.check_in_time");
});

test("Rails tool calls preserve the safe request correlation id", async () => {
  let receivedHeaders: HeadersInit | undefined;
  const fetchImpl = async (_url: URL | RequestInfo, init?: RequestInit) => {
    receivedHeaders = init?.headers;
    return {
      ok: true,
      status: 200,
      text: async () => JSON.stringify({ evidence: [] }),
    } as Response;
  };

  await callRailsTool(
    {
      base_url: "https://aylamanager.example",
      decision_context_id: "signed-context",
      correlation_id: "request-correlation-123",
    },
    "property_brain",
    { query: "cerradura" },
    { fetchImpl, token: "shared-token", environment: "production" },
  );

  assert.equal((receivedHeaders as Record<string, string>)["X-Request-ID"], "request-correlation-123");
});

test("production boot requires and reports the configured HTTPS Rails tools origin", () => {
  assert.throws(
    () => validateRailsToolClientBootConfig("production", { AI_SERVICE_TOKEN: "shared-token" }),
    /RAILS_TOOLS_BASE_URL is required/,
  );
  assert.throws(
    () => validateRailsToolClientBootConfig("production", {
      AI_SERVICE_TOKEN: "shared-token",
      RAILS_TOOLS_BASE_URL: "http://aylamanager.com",
    }),
    /must use HTTPS or a private Render HTTP address/,
  );
  assert.equal(
    validateRailsToolClientBootConfig("production", {
      AI_SERVICE_TOKEN: "shared-token",
      RAILS_TOOLS_BASE_URL: "http://staywise-ji62:10000",
    }),
    "http://staywise-ji62:10000",
  );
  assert.equal(
    validateRailsToolClientBootConfig("production", {
      AI_SERVICE_TOKEN: "shared-token",
      RAILS_TOOLS_BASE_URL: "https://ayla-manager-web.onrender.com",
    }),
    "https://ayla-manager-web.onrender.com",
  );
});

test("AI service configured Rails URL overrides the callback URL received from Rails", () => {
  assert.deepEqual(
    resolveRailsToolEndpoint(
      { base_url: "http://aylamanager.com", decision_context_id: "signed-context" },
      { RAILS_TOOLS_BASE_URL: "http://staywise-ji62:10000" },
    ),
    {
      base_url: "http://staywise-ji62:10000",
      decision_context_id: "signed-context",
    },
  );
});
