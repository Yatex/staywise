export function classifyTechnicalFallback(error: any, toolTrace: any[], generateObjectTrace: any[]) {
  const failedTool = toolTrace.find((tool) => tool?.error);
  const toolError = String(failedTool?.error || "");
  const modelErrors = generateObjectTrace
    .map((entry) => [entry?.error_name, entry?.error_class, entry?.error_message].filter(Boolean).join(" "))
    .join(" ");
  const errorText = [error?.name, error?.constructor?.name, error?.message, error?.cause?.code].filter(Boolean).join(" ");

  let type = "INTERNAL_EXCEPTION";
  let description = "Se produjo una excepción inesperada durante el procesamiento.";
  let provider: string | null = null;

  if (/tool_timeout|aborterror|timeouterror/i.test(toolError)) {
    type = "TOOL_TIMEOUT";
    description = "La respuesta quedó esperando una tool que excedió el tiempo máximo.";
    provider = "rails-tools";
  } else if (failedTool) {
    type = "TOOL_ERROR";
    description = "Una tool no pudo completar su ejecución.";
    provider = "rails-tools";
  } else if (/timeout|aborterror/i.test(`${modelErrors} ${errorText}`)) {
    type = "OPENAI_TIMEOUT";
    description = "La llamada al modelo superó el tiempo máximo.";
    provider = "openai";
  } else if (modelErrors) {
    type = "OPENAI_ERROR";
    description = "El proveedor del modelo devolvió un error.";
    provider = "openai";
  } else if (/ECONNRESET|ECONNREFUSED|ENOTFOUND|EAI_AGAIN|fetch failed/i.test(errorText)) {
    type = "NETWORK_ERROR";
    description = "No se pudo completar la comunicación con un servicio externo.";
  }

  return {
    type,
    description,
    tool: failedTool?.tool_name || null,
    tool_duration_ms: failedTool?.latency_ms ?? null,
    tools_executed: toolTrace.length,
    provider,
    exception_class: error?.constructor?.name || error?.name || null,
    exception_message: error?.message || String(error),
    timestamp: new Date().toISOString(),
  };
}
