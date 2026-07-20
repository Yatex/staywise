import { captureSafeException } from "./sentry.js";

export type RailsToolEndpoint = {
  base_url: string;
  decision_context_id: string;
  correlation_id?: string;
};

type RailsToolClientOptions = {
  fetchImpl?: typeof fetch;
  token?: string;
  environment?: string;
};

type RailsToolEnvironment = {
  AI_SERVICE_TOKEN?: string;
  RAILS_TOOLS_BASE_URL?: string;
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

  const baseUrl = validatedBaseUrl(toolEndpoint.base_url, options.environment || process.env.NODE_ENV);
  const url = new URL(`/internal/ai/tools/${toolName}`, baseUrl);
  const fetchImpl = options.fetchImpl || fetch;
  let response: Response;
  try {
    response = await fetchImpl(url, {
      method: "POST",
      redirect: "error",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
        ...(toolEndpoint.correlation_id ? { "X-Request-ID": toolEndpoint.correlation_id } : {}),
      },
      body: JSON.stringify({
        decision_context_id: toolEndpoint.decision_context_id,
        ...input,
      }),
    });
  } catch (error) {
    captureSafeException(error, {
      correlation_id: toolEndpoint.correlation_id,
      tool_name: toolName,
      error_code: "rails_tool_transport_error",
    });
    throw error;
  }

  const text = await response.text();
  const body = parseResponseBody(text);
  if (!response.ok) {
    captureSafeException(new Error(`Rails tool ${toolName} returned ${response.status}`), {
      correlation_id: toolEndpoint.correlation_id,
      tool_name: toolName,
      status: response.status,
    });
    return {
      error: "tool_request_failed",
      status: response.status,
      body,
    };
  }

  return body;
}

export function resolveRailsToolEndpoint(
  toolEndpoint: Partial<RailsToolEndpoint> | undefined,
  environment: RailsToolEnvironment = process.env,
): RailsToolEndpoint {
  return {
    base_url: environment.RAILS_TOOLS_BASE_URL || toolEndpoint?.base_url || "",
    decision_context_id: toolEndpoint?.decision_context_id || "",
    ...(toolEndpoint?.correlation_id ? { correlation_id: toolEndpoint.correlation_id } : {}),
  };
}

export function validateRailsToolClientBootConfig(
  nodeEnvironment = process.env.NODE_ENV,
  environment: RailsToolEnvironment = process.env,
) {
  if (nodeEnvironment !== "production") return null;
  if (!environment.AI_SERVICE_TOKEN) throw new Error("AI_SERVICE_TOKEN is required in production");
  if (!environment.RAILS_TOOLS_BASE_URL) throw new Error("RAILS_TOOLS_BASE_URL is required in production");

  const baseUrl = validatedBaseUrl(environment.RAILS_TOOLS_BASE_URL, nodeEnvironment);
  return new URL(baseUrl).origin;
}

function validatedBaseUrl(value: string, nodeEnvironment?: string) {
  if (!value) throw new Error("Rails tool base_url is required");

  const url = new URL(value);
  if (url.username || url.password) throw new Error("Rails tool base_url must not contain credentials");
  if (!["http:", "https:"].includes(url.protocol)) throw new Error("Rails tool base_url must use HTTP or HTTPS");

  if (nodeEnvironment === "production" && url.protocol !== "https:" && !isPrivateRenderHttpUrl(url)) {
    throw new Error(
      `Rails tool base_url must use HTTPS or a private Render HTTP address in production (received ${url.origin})`,
    );
  }

  return url.toString();
}

function isPrivateRenderHttpUrl(url: URL) {
  const singleLabelHostname = /^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/i.test(url.hostname);
  return url.protocol === "http:" &&
    singleLabelHostname &&
    url.hostname.toLowerCase() !== "localhost" &&
    url.port.length > 0;
}

function parseResponseBody(text: string) {
  if (!text) return null;

  try {
    return JSON.parse(text);
  } catch {
    return { raw_body: text.slice(0, 1_000) };
  }
}
