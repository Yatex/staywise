import { generateText, Output, stepCountIs, type LanguageModel } from "ai";
import { z } from "zod";
import { COPILOT_SYSTEM_PROMPT, CopilotResponseSchema } from "./copilot-schema.js";

type ToolCaller = (toolName: string, input: Record<string, unknown>) => Promise<unknown>;
type GenerateText = typeof generateText;

export type CopilotPayload = {
  guest_message: string;
  host_context?: string | null;
  property?: { id?: number; name?: string } | null;
  thread_history?: Array<{ role?: string; content?: string }>;
};

export async function runCopilot(options: {
  model: LanguageModel;
  payload: CopilotPayload;
  callTool: ToolCaller;
  abortSignal?: AbortSignal;
  generate?: GenerateText;
}) {
  const generate = options.generate || generateText;
  const authorizedEvidenceRefs = new Set<string>();
  const scopedToolCaller: ToolCaller = async (toolName, input) => {
    const result = await options.callTool(toolName, input);
    collectEvidenceRefs(result, authorizedEvidenceRefs);
    return result;
  };
  const tools = buildCopilotTools(options.payload, scopedToolCaller);
  const result = await generate({
    model: options.model,
    system: COPILOT_SYSTEM_PROMPT,
    prompt: JSON.stringify({
      selected_property: options.payload.property || null,
      guest_message: options.payload.guest_message,
      host_context: options.payload.host_context || null,
      thread_history: (options.payload.thread_history || []).slice(-12),
    }),
    tools,
    toolChoice: "auto",
    stopWhen: stepCountIs(6),
    experimental_output: Output.object({ schema: CopilotResponseSchema }),
    maxRetries: 0,
    abortSignal: options.abortSignal,
  });

  const output = CopilotResponseSchema.parse(result.experimental_output);
  return {
    output: {
      ...output,
      evidence_refs: output.evidence_refs.filter((reference) => authorizedEvidenceRefs.has(reference)),
    },
    usage: result.totalUsage || result.usage,
    steps: result.steps,
  };
}

function collectEvidenceRefs(value: unknown, references: Set<string>) {
  if (Array.isArray(value)) {
    value.forEach((item) => collectEvidenceRefs(item, references));
    return;
  }
  if (!value || typeof value !== "object") return;

  for (const [key, item] of Object.entries(value as Record<string, unknown>)) {
    if (key === "evidence_id" && typeof item === "string" && item.trim()) references.add(item.trim());
    collectEvidenceRefs(item, references);
  }
}

function buildCopilotTools(payload: CopilotPayload, callTool: ToolCaller) {
  const summary = (payload.thread_history || [])
    .slice(-12)
    .map((item) => `${item.role || "unknown"}: ${item.content || ""}`)
    .join("\n");

  return {
    property_brain: {
      description: "Search the selected property's authoritative knowledge, FAQs, policies, instructions, manuals, and relevant operational facts.",
      inputSchema: z.object({ query: z.string().min(1), limit: z.number().int().min(1).max(12).default(8) }),
      execute: ({ query, limit }: { query: string; limit: number }) => callTool("property_brain", {
        guest_message: query,
        conversation_summary: summary,
        limit,
      }),
    },
    search_property_knowledge: {
      description: "Run a focused search of the selected property's troubleshooting, access guidance, manuals, videos, and FAQs when a broad lookup was insufficient.",
      inputSchema: z.object({ query: z.string().min(1), topic: z.string().optional(), limit: z.number().int().min(1).max(12).default(8) }),
      execute: ({ query, topic, limit }: { query: string; topic?: string; limit: number }) => callTool("search_property_knowledge", { query, topic, limit }),
    },
    stay_facts: {
      description: "Retrieve only requested reservation or stay fields for the selected property's linked stay, when timing or booking context matters.",
      inputSchema: z.object({ requested_fields: z.array(z.string().min(1)).min(1).max(12) }),
      execute: ({ requested_fields }: { requested_fields: string[] }) => callTool("stay_facts", { requested_fields }),
    },
    guest_context: {
      description: "Retrieve scoped guest or reservation context only when the host's question depends on the guest or their stay.",
      inputSchema: z.object({ query: z.string().min(1) }),
      execute: ({ query }: { query: string }) => callTool("guest_context", { query }),
    },
    sensitive_access_info: {
      description: "Retrieve sensitive access information for the selected property. This is the only allowed source for codes, keys, lockboxes, or protected entry details.",
      inputSchema: z.object({ query: z.string().min(1) }),
      execute: ({ query }: { query: string }) => callTool("sensitive_access_info", { guest_message: query }),
    },
    recommendations: {
      description: "Retrieve approved recommendations associated with the selected property for relevant local recommendation questions.",
      inputSchema: z.object({ query: z.string().min(1), category: z.string().optional() }),
      execute: ({ query, category }: { query: string; category?: string }) => callTool("approved_recommendations", { query, category }),
    },
  };
}
