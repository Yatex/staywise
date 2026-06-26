import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { gateway, generateObject, generateText, stepCountIs } from "ai";
import { z } from "zod";

const EvidenceSchema = z.object({
  source_type: z.enum([
    "reservation_fact",
    "property_fact",
    "faq",
    "knowledge_block",
    "recommendation",
    "policy",
  ]),
  source_id: z.string(),
  claim: z.string(),
});

const DecisionSchema = z.object({
  outcome: z.enum([
    "reply",
    "ask_clarifying_question",
    "escalate",
    "propose_action",
    "no_reply",
  ]),
  response_text: z.string().nullable(),
  confidence: z.number().min(0).max(1),
  evidence: z.array(EvidenceSchema).default([]),
  escalation: z.object({
    required: z.boolean(),
    category: z
      .enum([
        "emergency",
        "maintenance",
        "complaint",
        "booking_change",
        "refund",
        "access",
        "unknown",
      ])
      .nullable(),
    urgency: z.enum(["low", "medium", "high", "urgent"]).nullable(),
    summary: z.string().nullable(),
  }),
  proposed_action: z
    .object({
      type: z.enum([
        "early_checkin_request",
        "late_checkout_request",
        "maintenance_request",
        "refund_request",
        "booking_change_request",
        "access_request",
      ]),
      requires_approval: z.boolean(),
      details: z.string().nullable(),
    })
    .nullable(),

  // Backward-compatible fields consumed by the existing Rails alert path.
  should_reply: z.boolean().optional(),
  escalation_required: z.boolean().optional(),
  alert_type: z
    .enum([
      "late_checkout_request",
      "missing_item",
      "maintenance_issue",
      "emergency",
      "complaint",
      "owner_approval_required",
      "unknown_question",
      "other",
    ])
    .optional()
    .nullable(),
  alert_title: z.string().optional().nullable(),
  alert_description: z.string().optional().nullable(),
  suggested_owner_action: z.string().optional().nullable(),
});

const server = createServer(async (request, response) => {
  if (request.method === "GET" && request.url === "/health") {
    sendJson(response, 200, { ok: true });
    return;
  }

  if (request.method !== "POST" || request.url !== "/decide") {
    sendJson(response, 404, { error: "Not found" });
    return;
  }

  if (!authorized(request)) {
    sendJson(response, 401, { error: "Unauthorized" });
    return;
  }

  try {
    const body = await readBody(request);
    const payload = JSON.parse(body || "{}");

    if (!gatewayConfigured()) {
      sendJson(response, 200, fallbackDecision(payload));
      return;
    }

    const toolResults = await collectToolResults(payload);
    const result = await generateObject({
      model: gatewayModel(),
      schema: DecisionSchema,
      schemaName: "AylaDecision",
      system: [
        "You are Ayla, an AI guest assistant for short-term rentals.",
        "Answer only from the provided tool results.",
        "Every reply must cite one or more evidence items from those tool results.",
        "Do not invent source IDs, property facts, rules, prices, availability, refunds, or policies.",
        "Never approve early check-in, late checkout, refunds, discounts, compensation, reservation changes, maintenance commitments, emergency dispatch, or access outside permitted windows.",
        "If information is missing or approval is needed, escalate or propose an action requiring approval.",
        "Keep replies friendly, helpful, concise, and in the guest language when possible.",
      ].join("\n"),
      prompt: JSON.stringify({
        base_context: safeBaseContext(payload),
        tool_results: toolResults,
      }),
    });

    sendJson(response, 200, {
      ...result.object,
      should_reply: result.object.outcome !== "no_reply" && Boolean(result.object.response_text),
      escalation_required: result.object.escalation.required,
      audit: {
        model: gatewayModelId(),
        tool_results: summarizeToolResults(toolResults),
        token_usage: result.usage,
      },
    });
  } catch (error) {
    console.error("[ai-service]", error);
    sendJson(response, 500, {
      error: "AI decision failed",
      ...fallbackDecision({ guest_message: "No se pudo procesar la consulta del huésped." }),
    });
  }
});

server.listen(Number(process.env.PORT || 8787), () => {
  console.log(`Ayla AI service listening on ${process.env.PORT || 8787}`);
});

function readBody(request: NodeJS.ReadableStream): Promise<string> {
  return new Promise((resolve, reject) => {
    let body = "";
    request.on("data", (chunk) => {
      body += chunk;
    });
    request.on("end", () => resolve(body));
    request.on("error", reject);
  });
}

function authorized(request: IncomingMessage) {
  const expectedToken = process.env.AI_SERVICE_TOKEN;
  if (!expectedToken) return true;

  const authorization = request.headers.authorization;
  return authorization === `Bearer ${expectedToken}`;
}

function sendJson(response: ServerResponse, status: number, payload: unknown) {
  response.writeHead(status, { "content-type": "application/json" });
  response.end(JSON.stringify(payload));
}

function gatewayModelId() {
  return process.env.AI_MODEL || "openai/gpt-5-mini";
}

function gatewayModel() {
  return gateway(gatewayModelId());
}

function gatewayConfigured() {
  return Boolean(
    process.env.AI_GATEWAY_API_KEY ||
      process.env.VERCEL_OIDC_TOKEN ||
      process.env.VERCEL,
  );
}

function fallbackDecision(payload: any) {
  return {
    outcome: "escalate",
    response_text:
      "Thanks for your message. I'm checking this with the host and will get back to you shortly.",
    should_reply: true,
    confidence: 0.25,
    evidence: [],
    escalation: {
      required: true,
      category: "unknown",
      urgency: "medium",
      summary: payload?.guest_message || "The guest asked a question the AI service could not answer.",
    },
    proposed_action: null,
    escalation_required: true,
    alert_type: "unknown_question",
    alert_title: "Pregunta pendiente del anfitrión",
    alert_description: payload?.guest_message || "El huésped hizo una pregunta que la IA no pudo responder.",
    suggested_owner_action: "Agregá la respuesta a la guía o FAQ de la propiedad y luego respondé al huésped.",
  };
}

function safeBaseContext(payload: any) {
  return {
    guest_message: payload?.guest_message,
    guest: payload?.guest,
    property: payload?.property,
    reservation: payload?.reservation,
    owner_instructions: payload?.owner_instructions,
    conversation_history: payload?.conversation_history,
    safety_rules: payload?.safety_rules,
  };
}

async function collectToolResults(payload: any) {
  if (process.env.AI_TOOLS_ENABLED === "false") return [];

  const result = await generateText({
    model: gatewayModel(),
    system: [
      "You select the minimum read-only Ayla tools needed to answer or classify the guest message.",
      "Never request arbitrary record IDs. Tools are scoped to the current conversation by the server.",
      "Do not provide a final guest answer. Return a short retrieval summary after tool calls.",
    ].join("\n"),
    prompt: JSON.stringify(safeBaseContext(payload)),
    tools: buildTools(payload?.tool_context || {}),
    stopWhen: stepCountIs(3),
  });

  return result.toolResults.map((toolResult: any) => ({
    toolName: toolResult.toolName,
    input: toolResult.input,
    result: toolResult.output,
  }));
}

function buildTools(toolContext: any) {
  return {
    get_stay_facts: {
      description: "Get exact, non-sensitive stay or property facts scoped to the current conversation.",
      inputSchema: z.object({
        requested_fields: z.array(
          z.enum([
            "check_in_time",
            "check_out_time",
            "address",
            "parking",
            "rules",
            "reservation_dates",
            "reservation_status",
          ]),
        ),
      }),
      execute: async ({ requested_fields }: { requested_fields: string[] }) => {
        return requested_fields
          .map((field) => {
            if (field === "reservation_dates" || field === "reservation_status") {
              return toolContext.reservation_facts?.[field];
            }
            return toolContext.safe_property_facts?.[field];
          })
          .filter(Boolean);
      },
    },
    search_property_knowledge: {
      description: "Search owner-provided FAQs and guide blocks scoped to the current property.",
      inputSchema: z.object({
        query: z.string(),
        topic: z.enum(["faq", "house_rules", "troubleshooting", "general"]).optional(),
      }),
      execute: async ({ query, topic }: { query: string; topic?: string }) => {
        const candidates = [
          ...(toolContext.faqs || []),
          ...(toolContext.knowledge_blocks || []),
        ];
        return searchSources(candidates, query, topic).slice(0, 5);
      },
    },
    get_approved_recommendations: {
      description: "Get owner-approved local recommendations scoped to the current property.",
      inputSchema: z.object({
        category: z.enum([
          "restaurant",
          "breakfast",
          "coffee",
          "pharmacy",
          "transport",
          "supermarket",
          "activities",
        ]),
      }),
      execute: async ({ category }: { category: string }) => {
        const normalizedCategory = category === "coffee" ? "cafe" : category === "activities" ? "attraction" : category;
        return (toolContext.recommendations || [])
          .filter((source: any) => source.value?.toLowerCase().includes(normalizedCategory) || source.label?.toLowerCase().includes(normalizedCategory))
          .slice(0, 5);
      },
    },
    get_access_instructions: {
      description: "Get sensitive access instructions only when Rails has authorized disclosure for this guest and reservation window.",
      inputSchema: z.object({}),
      execute: async () => {
        if (!toolContext.sensitive_access_authorized) {
          return { denied: true, reason: "Sensitive access is not authorized for this guest/reservation window." };
        }
        return Object.values(toolContext.sensitive_property_facts || {});
      },
    },
    get_property_policy: {
      description: "Get owner policy scoped to this account/property. Policies do not grant approval by themselves.",
      inputSchema: z.object({
        policy_type: z.enum(["early_checkin", "late_checkout", "refund", "maintenance", "access"]),
      }),
      execute: async ({ policy_type }: { policy_type: string }) => {
        return toolContext.policies?.[policy_type] || {
          source_type: "policy",
          source_id: `policy:${policy_type}`,
          label: policy_type,
          value: "Escalate to the host for approval.",
        };
      },
    },
    create_escalation_draft: {
      description: "Create an escalation draft. This does not write to the database; Rails decides whether to create the real alert.",
      inputSchema: z.object({
        category: z.string(),
        urgency: z.string(),
        summary: z.string(),
      }),
      execute: async (input: { category: string; urgency: string; summary: string }) => ({
        draft: true,
        ...input,
      }),
    },
  };
}

function searchSources(sources: any[], query: string, topic?: string) {
  const words = query
    .toLowerCase()
    .split(/[^a-z0-9áéíóúüñ]+/i)
    .filter((word) => word.length >= 4);

  return sources
    .map((source) => {
      const haystack = [source.label, source.value, source.source_type].join(" ").toLowerCase();
      const score = words.filter((word) => haystack.includes(word)).length + (topic && haystack.includes(topic) ? 1 : 0);
      return { source, score };
    })
    .filter((item) => item.score > 0)
    .sort((a, b) => b.score - a.score)
    .map((item) => item.source);
}

function summarizeToolResults(toolResults: any[]) {
  return toolResults.map((item) => ({
    toolName: item.toolName,
    source_ids: Array.isArray(item.result)
      ? item.result.map((source: any) => source?.source_id).filter(Boolean)
      : [item.result?.source_id].filter(Boolean),
  }));
}
