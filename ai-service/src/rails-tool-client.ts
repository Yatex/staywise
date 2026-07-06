export type RailsToolEndpoint = {
  base_url: string;
  decision_context_id: string;
};

type RailsToolClientOptions = {
  fetchImpl?: typeof fetch;
  token?: string;
};

export async function callRailsTool(
  toolEndpoint: RailsToolEndpoint,
  toolName: string,
  input: Record<string, unknown>,
  options: RailsToolClientOptions = {},
) {
  const token = options.token !== undefined ? options.token : process.env.AI_SERVICE_TOKEN;
  if (!token) throw new Error("AI_SERVICE_TOKEN is required for Rails tool calls");
  if (token !== token.trim()) throw new Error("AI_SERVICE_TOKEN contains surrounding whitespace");

  if (!toolEndpoint?.base_url) throw new Error("Rails tool base_url is required");
  if (!toolEndpoint?.decision_context_id) throw new Error("decision_context_id is required for Rails tool calls");

  const url = new URL(`/internal/ai/tools/${toolName}`, toolEndpoint.base_url);
  const fetchImpl = options.fetchImpl || fetch;
  const response = await fetchImpl(url, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      decision_context_id: toolEndpoint.decision_context_id,
      ...input,
    }),
  });

  const text = await response.text();
  const body = parseResponseBody(text);
  if (!response.ok) {
    return {
      error: "tool_request_failed",
      status: response.status,
      body,
    };
  }

  return body;
}

function parseResponseBody(text: string) {
  if (!text) return null;

  try {
    return JSON.parse(text);
  } catch {
    return { raw_body: text.slice(0, 1_000) };
  }
}
