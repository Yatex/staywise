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

  let payload: any = {};

  try {
    const body = await readBody(request);
    payload = JSON.parse(body || "{}");

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
        "If the guest only greets, sends the default QR/link message, or has not asked a substantive property question, respond with a friendly clarifying question. This does not require evidence.",
        "If the guest question is ambiguous but likely refers to known property facts, ask one friendly clarifying question. This does not require evidence and must not create an owner escalation.",
        "For ambiguous time questions like 'what time can I go?' or 'a qué hora puedo ir?', ask whether the guest means arrival/check-in or departure/checkout.",
        "Do not invent source IDs, property facts, rules, prices, availability, refunds, or policies.",
        "Never approve early check-in, late checkout, refunds, discounts, compensation, reservation changes, maintenance commitments, emergency dispatch, or access outside permitted windows.",
        "Escalate or propose an action requiring approval only when information is truly missing, the guest asks for an exception/approval, or a clarification cannot resolve the request.",
        "Guest-facing response_text must be written in the guest language from base_context.guest_language or inferred from base_context.guest_message.",
        "Owner-facing fields alert_title, alert_description, suggested_owner_action, and escalation.summary must be written in the owner language from base_context.owner_language. Use Spanish when owner_language is es or missing.",
        "Never use owner-facing Spanish as the guest reply when the guest wrote in another language.",
        "Keep replies friendly, helpful, and concise.",
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
    sendJson(response, 200, {
      ...fallbackDecision(payload),
      audit: {
        fallback: true,
        error: error instanceof Error ? error.message : String(error),
      },
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
  const guestText = payload?.guest_message || "";
  const ownerLanguage = payload?.owner_language || payload?.owner_instructions?.ai_preferred_language || "es";
  return {
    outcome: "escalate",
    response_text: safeAckFor(guestText, payload?.guest_language),
    should_reply: true,
    confidence: 0.25,
    evidence: [],
    escalation: {
      required: true,
      category: "unknown",
      urgency: "medium",
      summary: ownerText(
        ownerLanguage,
        "El huésped hizo una pregunta que el servicio de IA no pudo responder.",
        "The guest asked a question the AI service could not answer.",
      ),
    },
    proposed_action: null,
    escalation_required: true,
    alert_type: "unknown_question",
    alert_title: ownerText(ownerLanguage, "Pregunta pendiente del anfitrión", "Question pending host response"),
    alert_description: payload?.guest_message || ownerText(ownerLanguage, "El huésped hizo una pregunta que la IA no pudo responder.", "The guest asked a question the AI could not answer."),
    suggested_owner_action: ownerText(
      ownerLanguage,
      "Agregá la respuesta a la guía o FAQ de la propiedad y luego respondé al huésped.",
      "Add the answer to the property guide or FAQ, then reply to the guest.",
    ),
  };
}

function safeBaseContext(payload: any) {
  return {
    guest_message: payload?.guest_message,
    guest_language: payload?.guest_language,
    owner_language: payload?.owner_language,
    guest: payload?.guest,
    property: payload?.property,
    reservation: payload?.reservation,
    owner_instructions: payload?.owner_instructions,
    conversation_history: payload?.conversation_history,
    safety_rules: payload?.safety_rules,
  };
}

function safeAckFor(text: string, language?: string) {
  const detected = normalizeLanguage(language) || detectLanguage(text);

  switch (detected) {
    case "es":
      return "Gracias por tu mensaje. Lo estoy consultando con el anfitrión y te responderé en breve.";
    case "fr":
      return "Merci pour votre message. Je vérifie cela avec l'hôte et je vous répondrai bientôt.";
    case "de":
      return "Danke für deine Nachricht. Ich kläre das mit dem Gastgeber und melde mich in Kürze.";
    case "pt":
      return "Obrigado pela mensagem. Vou verificar isso com o anfitrião e respondo em breve.";
    case "it":
      return "Grazie per il messaggio. Verifico con l'host e ti rispondo a breve.";
    case "zh":
      return "谢谢你的消息。我会向房东确认，并尽快回复你。";
    case "ja":
      return "メッセージありがとうございます。ホストに確認して、できるだけ早く返信します。";
    case "ko":
      return "메시지 감사합니다. 호스트에게 확인한 뒤 곧 답변드리겠습니다.";
    case "ar":
      return "شكرًا على رسالتك. سأتحقق من ذلك مع المضيف وأرد عليك قريبًا.";
    case "he":
      return "תודה על ההודעה. אבדוק זאת מול המארח ואחזור אליך בקרוב.";
    case "ru":
      return "Спасибо за сообщение. Я уточню это у хозяина и скоро отвечу.";
    default:
      return "Thanks for your message. I'm checking this with the host and will get back to you shortly.";
  }
}

function detectLanguage(text: string) {
  if (/[\u4E00-\u9FFF]/u.test(text)) return "zh";
  if (/[\u3040-\u30FF]/u.test(text)) return "ja";
  if (/[\uAC00-\uD7AF]/u.test(text)) return "ko";
  if (/[\u0600-\u06FF]/u.test(text)) return "ar";
  if (/[\u0590-\u05FF]/u.test(text)) return "he";
  if (/[\u0400-\u04FF]/u.test(text)) return "ru";

  const normalized = text.toLowerCase();
  if (/\b(y|el|la|los|las|un|una|del|de|mi|tu|para)\b.*\bcheck\s*-?\s*out\b/u.test(normalized)) return "es";
  if (/\bcheck\s*-?\s*out\b.*\b(y|el|la|los|las|un|una|del|de|mi|tu|para)\b/u.test(normalized)) return "es";
  if (/\b(qué|que|dónde|donde|cuándo|cuando|cómo|como|hola|gracias|necesito|puedo|quisiera|quiero|saber|salida|entrada|red|clave|contraseña|contrasena|anfitri[oó]n)\b/u.test(normalized)) return "es";
  if (/\b(bonjour|merci|où|ou|quand|comment|puis-je|hôte|hote|propriétaire|proprietaire)\b/u.test(normalized)) return "fr";
  if (/\b(hallo|danke|wo|wann|wie|kann ich|gastgeber|vermieter)\b/u.test(normalized)) return "de";
  if (/\b(olá|ola|obrigado|obrigada|onde|quando|como|posso|anfitrião|anfitriao)\b/u.test(normalized)) return "pt";
  if (/\b(ciao|grazie|dove|quando|come|posso|host|proprietario)\b/u.test(normalized)) return "it";

  return "en";
}

function normalizeLanguage(language?: string) {
  return language?.split(/[-_]/)[0] || undefined;
}

function ownerText(language: string, spanish: string, english: string) {
  return normalizeLanguage(language) === "en" ? english : spanish;
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
        topic: z.enum(["faq", "house_rules", "appliances", "troubleshooting", "general"]).optional(),
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
  const words = searchTokens(query);

  return sources
    .map((source) => {
      const haystack = [source.label, source.value, source.category, source.source_type].join(" ").toLowerCase();
      const sourceWords = searchTokens(haystack);
      const score = words.reduce((total, word) => {
        if (sourceWords.includes(word)) return total + 3;
        if (word.length >= 5 && sourceWords.some((sourceWord) => sourceWord.length >= 5 && editDistanceAtMostOne(word, sourceWord))) {
          return total + 2;
        }
        return total;
      }, topic && haystack.includes(topic) ? 1 : 0);
      return { source, score };
    })
    .filter((item) => item.score > 0)
    .sort((a, b) => b.score - a.score)
    .map((item) => item.source);
}

function searchTokens(value: string) {
  const stopwords = new Set([
    "como", "cual", "cuando", "donde", "para", "porque", "quien", "algo",
    "esta", "este", "esto", "tengo", "quiero", "puedo", "llego",
    "what", "where", "when", "with", "this", "that", "there", "please",
  ]);

  return Array.from(
    new Set(
      value
        .toLowerCase()
        .normalize("NFD")
        .replace(/\p{Diacritic}/gu, "")
        .replace(/\bq\b/g, " que ")
        .split(/[^a-z0-9]+/i)
        .filter((word) => word.length >= 4 && !stopwords.has(word)),
    ),
  );
}

function editDistanceAtMostOne(left: string, right: string) {
  if (left === right) return true;
  if (Math.abs(left.length - right.length) > 1) return false;

  let i = 0;
  let j = 0;
  let edits = 0;

  while (i < left.length && j < right.length) {
    if (left[i] === right[j]) {
      i += 1;
      j += 1;
    } else if (edits === 0) {
      edits += 1;
      if (left.length > right.length) {
        i += 1;
      } else if (right.length > left.length) {
        j += 1;
      } else {
        i += 1;
        j += 1;
      }
    } else {
      return false;
    }
  }

  return edits + (left.length - i) + (right.length - j) <= 1;
}

function summarizeToolResults(toolResults: any[]) {
  return toolResults.map((item) => ({
    toolName: item.toolName,
    source_ids: Array.isArray(item.result)
      ? item.result.map((source: any) => source?.source_id).filter(Boolean)
      : [item.result?.source_id].filter(Boolean),
  }));
}
