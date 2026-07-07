import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { gateway, generateObject, generateText, stepCountIs } from "ai";
import { z } from "zod";
import {
  callRailsTool,
  resolveRailsToolEndpoint,
  validateRailsToolClientBootConfig,
} from "./rails-tool-client.js";
import {
  buildEvidenceCatalog,
  canonicalEvidenceId,
  shouldRetryGroundedDecision,
} from "./evidence-catalog.js";
import { buildGroundedDecision } from "./grounded-decision-builder.js";

const DecisionSchema = z.object({
  outcome: z.enum([
    "reply",
    "ask_clarifying_question",
    "escalate",
    "propose_action",
    "ignore",
    "no_reply",
  ]),
  language: z.string(),
  message_body: z.string().nullable(),
  intent_summary: z.string(),
  detected_intents: z.array(z.object({
    type: z.string(),
    status: z.enum([
      "answered",
      "needs_clarification",
      "requires_host_approval",
      "escalated",
    ]),
  })).default([]),
  used_source_ids: z.array(z.string()).default([]),
  evidence_ids: z.array(z.string()).default([]),
  required_capabilities: z.array(z.string()).default([]),
  proposed_action: z
    .object({
      type: z.enum([
        "request_early_checkin",
        "request_late_checkout",
        "request_reservation_extension",
        "report_issue",
        "human_handoff",
        "none",
      ]),
      payload: z.record(z.unknown()).default({}),
    })
    .nullable(),
  escalation: z.object({
    required: z.boolean(),
    reason_code: z.string().nullable(),
    summary_for_host: z.string().nullable(),
  }),
  escalation_required: z.boolean(),
  escalation_reason: z.string().nullable(),
  sensitive_info_used: z.boolean().default(false),
  missing_information: z.array(z.string()).default([]),
  safety_flags: z.array(z.string()).default([]),
  confidence: z.number().min(0).max(1),
}).strict();

const PropertyImportSchema = z.object({
  property: z.object({
    name: z.string().nullable().optional(),
    address: z.string().nullable().optional(),
    internal_nickname: z.string().nullable().optional(),
    check_in_time: z.string().nullable().optional(),
    checkout_time: z.string().nullable().optional(),
    wifi_name: z.string().nullable().optional(),
    wifi_password: z.string().nullable().optional(),
    house_rules: z.string().nullable().optional(),
    access_instructions: z.string().nullable().optional(),
    parking_instructions: z.string().nullable().optional(),
    emergency_information: z.string().nullable().optional(),
    owner_contact_instructions: z.string().nullable().optional(),
    ai_general_notes: z.string().nullable().optional(),
    tag_list: z.string().nullable().optional(),
  }),
  faqs: z.array(
    z.object({
      question: z.string(),
      answer: z.string(),
      category: z.string().nullable().optional(),
    }),
  ).default([]),
  source_summary: z.string().nullable().optional(),
});

const TranslationSchema = z.object({
  translated_text: z.string(),
}).strict();

type MandatoryToolName = "guest_context" | "stay_facts" | "property_brain";

type MandatoryToolStatus = {
  attempted: boolean;
  success: boolean;
  error: string | null;
};

type ToolMandatoryTrace = {
  message_received: string | null;
  is_real_guest_message: boolean;
  should_run_tools: boolean;
  skip_reason: string | null;
  decision_context_id_present: boolean;
  tool_endpoint_present: boolean;
  tool_endpoint_origin: string | null;
  authorization_configured: boolean;
  authorization_source: "AI_SERVICE_TOKEN";
  authorization_scheme: "Bearer";
  authorization_header_sent: boolean;
  token_has_surrounding_whitespace: boolean;
  token_wrapped_in_quotes: boolean;
  guest_context: MandatoryToolStatus;
  stay_facts: MandatoryToolStatus;
  property_brain: MandatoryToolStatus;
  tool_execution_time_ms: number | null;
  final_tools: any[];
};

const server = createServer(async (request, response) => {
  if (request.method === "GET" && request.url === "/health") {
    sendJson(response, 200, { ok: true });
    return;
  }

  if (request.method !== "POST" || !["/decide", "/property_import", "/translate"].includes(request.url || "")) {
    sendJson(response, 404, { error: "Not found" });
    return;
  }

  if (!authorized(request)) {
    sendJson(response, 401, { error: "Unauthorized" });
    return;
  }

  let payload: any = {};
  const toolTrace: any[] = [];
  let mandatoryTrace = newToolMandatoryTrace(payload);

  try {
    const body = await readBody(request);
    payload = JSON.parse(body || "{}");
    mandatoryTrace = newToolMandatoryTrace(payload);

    if (request.url === "/property_import") {
      await handlePropertyImport(payload, response);
      return;
    }

    if (request.url === "/translate") {
      await handleTranslate(payload, response);
      return;
    }

    payload.tool_endpoint = resolveRailsToolEndpoint(payload?.tool_endpoint);
    mandatoryTrace = newToolMandatoryTrace(payload);

    if (isConversationalClosure(payload?.guest_message)) {
      mandatoryTrace.skip_reason = "conversational_closure";
      emitToolMandatoryTrace(mandatoryTrace, toolTrace);
      sendJson(response, 200, closureDecision(payload));
      return;
    }

    if (!gatewayConfigured()) {
      mandatoryTrace.skip_reason = "gateway_not_configured";
      emitToolMandatoryTrace(mandatoryTrace, toolTrace);
      sendJson(response, 200, withToolMandatoryAudit(fallbackDecision(payload), toolTrace, mandatoryTrace));
      return;
    }

    const toolResults = await collectToolResults(payload, toolTrace, mandatoryTrace);
    const evidenceCatalog = buildEvidenceCatalog(toolResults);
    const modelInputTrace = buildModelInputTrace(payload, toolResults, evidenceCatalog);
    console.log("MODEL_INPUT_TRACE", JSON.stringify(modelInputTrace));
    let result = await generateObject({
      model: gatewayModel(),
      schema: DecisionSchema,
      schemaName: "AylaDecision",
      system: [
        "You are Ayla, an AI guest assistant for short-term rentals.",
        "You are tool-first: use tools to understand and answer factual questions. Do not answer factual property or reservation questions from memory.",
        "You must use property_brain first for property, reservation, policy, FAQ, guide, amenity, appliance, recommendation, and operational questions.",
        "If the guest asks about WiFi, passwords, codes, keys, lockboxes, exact access instructions, entrance, or other sensitive access details, you must also call sensitive_access_info.",
        "If the answer needs owner approval or the available evidence does not directly answer the guest, call create_escalation_draft and return outcome escalate or propose_action.",
        "Answer only from provided tool results.",
        "Every factual reply must cite evidence returned by tools. Use evidence_ids for evidence_id values and used_source_ids for source id values.",
        "Do not invent evidence or source IDs. Every cited ID must appear in evidence_catalog or tool_results.",
        "If evidence_catalog contains sufficient evidence for the guest's request, answer with that evidence instead of returning unknown, fallback, or escalation.",
        "Evaluate evidence sufficiency generically across property facts, guest context, property brain, FAQs, guides, knowledge blocks, approved recommendations, policies, and future sources.",
        "When sensitive_access_info is used for the guest reply, set sensitive_info_used=true and cite only sensitive source IDs for the sensitive facts.",
        "The cited evidence must directly answer the guest's latest question. If a tool result is about a different topic, ignore it.",
        "Before interpreting requests, check whether the latest guest message is a conversational closure, thanks, acknowledgement, or rejection of extra help.",
        "If the guest says things like 'gracias', 'muchas gracias', 'perfecto', 'ok', 'dale', 'entendido', 'listo', 'no gracias', 'así está bien', 'genial', or 'excelente', return outcome no_reply. Do not escalate, ask clarification, create actions, or consult the host.",
        "Use recommendations only when the guest asks for places, restaurants, transport, pharmacies, supermarkets, attractions, money exchange, or similar local recommendations.",
        "Never answer a building guide, laundry, visitor, pool permission, booking change, or appliance question with unrelated check-in, checkout, YouTube music, map, restaurant, or money-exchange content.",
        "If the guest only greets, sends the default QR/link message, or has not asked a substantive property question, respond with a friendly clarifying question. This does not require evidence.",
        "If the guest question is ambiguous but likely refers to known property facts, ask one friendly clarifying question. This does not require evidence and must not create an owner escalation.",
        "For ambiguous time questions like 'what time can I go?' or 'a qué hora puedo ir?', ask whether the guest means arrival/check-in or departure/checkout.",
        "Do not invent source IDs, property facts, rules, prices, availability, refunds, or policies.",
        "Never approve early check-in, late checkout, refunds, discounts, compensation, reservation changes, maintenance commitments, emergency dispatch, or access outside permitted windows.",
        "For late checkout, early check-in, reservation changes, refunds, discounts, visitors, pets, or exceptions, do not promise approval. Escalate or propose an action unless a returned policy explicitly says the request is allowed without owner approval.",
        "Escalate or propose an action requiring approval only when information is truly missing, the guest asks for an exception/approval, or a clarification cannot resolve the request.",
        "Determine the language of the latest guest message yourself and set the language field to that language.",
        "Write guest-facing message_body in the language of the latest guest message.",
        "If the guest changes language, change language and message_body to the new language even when earlier conversation messages used another language.",
        "Use base_context.guest_language_fallback only when the latest guest message is too short or unclear to identify a language.",
        "Owner-facing escalation.summary_for_host must be written in the owner language from base_context.owner_language. Use Spanish when owner_language is es or missing.",
        "Never use owner-facing Spanish as the guest reply when the guest wrote in another language.",
        "If multiple intents are present, every intent must be answered, marked needs_clarification, requires_host_approval, or escalated.",
        "Do not say the host was notified unless decision is escalate or propose_action with escalation.required=true.",
        "Keep replies friendly, helpful, and concise.",
      ].join("\n"),
      prompt: JSON.stringify({
        base_context: safeBaseContext(payload),
        tool_results: toolResults,
        evidence_catalog: evidenceCatalog,
      }),
    });

    let groundingRetry = false;
    let retryModelInputTrace: any = null;
    if (shouldRetryGroundedDecision(result.object, evidenceCatalog)) {
      groundingRetry = true;
      const previousDecisionForTrace = result.object as any;
      retryModelInputTrace = buildModelInputTrace(payload, toolResults, evidenceCatalog, {
        previous_decision_outcome: previousDecisionForTrace?.outcome || previousDecisionForTrace?.decision || null,
        previous_decision_intents: previousDecisionForTrace?.detected_intents || [],
        previous_decision_evidence_ids: previousDecisionForTrace?.evidence_ids || [],
      });
      console.log("MODEL_INPUT_TRACE", JSON.stringify({ ...retryModelInputTrace, retry: true }));
      result = await generateObject({
        model: gatewayModel(),
        schema: DecisionSchema,
        schemaName: "AylaGroundedDecisionReview",
        system: [
          "Review an Ayla guest decision that escalated as unknown even though tools returned evidence.",
          "Interpret the latest guest message and use only evidence_catalog and tool_results.",
          "If the evidence directly answers the question, return outcome reply, the specific answered intent, a friendly answer in the latest guest message's language, and the exact evidence_ids.",
          "Evaluate evidence sufficiency generically across all returned sources, not by hardcoded topic.",
          "Do not escalate when direct evidence answers the question. Do not invent facts or IDs.",
          "Keep escalation only when the available evidence truly does not answer or owner approval is required.",
        ].join("\n"),
        prompt: JSON.stringify({
          base_context: safeBaseContext(payload),
          tool_results: toolResults,
          evidence_catalog: evidenceCatalog,
          previous_decision: result.object,
        }),
      });
    }
    const groundedDecision = buildGroundedDecision(result.object, payload, evidenceCatalog);
    const finalDecision = groundedDecision.decision;
    const finalDecisionAudit = {
      ...((finalDecision as any).audit || {}),
    };
    if (finalDecisionAudit.grounded_decision_builder) {
      finalDecisionAudit.grounded_decision_builder = {
        ...finalDecisionAudit.grounded_decision_builder,
        final_decision_source: {
          model: !groundingRetry && !groundedDecision.override?.applied,
          retry_model: groundingRetry && !groundedDecision.override?.applied,
          grounded_override: Boolean(groundedDecision.override?.applied),
          fallback: false,
        },
      };
    }
    const finalDecisionSource = finalDecisionAudit.grounded_decision_builder?.final_decision_source || {
      model: !groundingRetry,
      retry_model: groundingRetry,
      grounded_override: false,
      fallback: false,
    };

    emitToolMandatoryTrace(mandatoryTrace, toolTrace);
    sendJson(response, 200, {
      ...finalDecision,
      audit: {
        ...finalDecisionAudit,
        model: gatewayModelId(),
        model_input_trace: {
          initial: modelInputTrace,
          retry: retryModelInputTrace,
        },
        grounded_decision_trace: finalDecisionAudit.grounded_decision_builder || { called: false },
        final_decision_source: finalDecisionSource,
        token_usage: result.usage,
        tool_calls: toolTrace,
        evidence_catalog: evidenceCatalog,
        grounding_retry: groundingRetry,
        grounded_decision_override: groundedDecision.override,
        tool_mandatory_trace: finalizeToolMandatoryTrace(mandatoryTrace, toolTrace),
      },
    });
  } catch (error) {
    console.error("[ai-service]", error);
    emitToolMandatoryTrace(mandatoryTrace, toolTrace);
    sendJson(response, 200, withToolMandatoryAudit(fallbackDecision(payload), toolTrace, mandatoryTrace));
  }
});

const railsToolsOrigin = validateRailsToolClientBootConfig();
if (railsToolsOrigin) console.log(`[rails-tool-client] configured origin=${railsToolsOrigin}`);

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

async function handlePropertyImport(payload: any, response: ServerResponse) {
  if (!gatewayConfigured()) {
    sendJson(response, 503, { error: "AI gateway is not configured" });
    return;
  }

  const document = payload?.document || {};
  const result = await generateObject({
    model: gatewayModel(),
    schema: PropertyImportSchema,
    schemaName: "AylaPropertyImport",
    system: [
      "You extract short-term rental property setup data for Ayla Manager.",
      "Extract only information explicitly present in the uploaded document/image. The current property is context only; do not echo existing fields unless the upload confirms or updates them.",
      "Do not invent facts, amenities, rules, prices, availability, policies, addresses, codes, or passwords.",
      "Prefer the document/image when it conflicts with blank current property fields. Preserve the owner's language for long text fields.",
      "Normalize check-in and checkout times as short readable values like '15:00' or '11:00'.",
      "Put appliance guides, amenity notes, pool/building directions, and miscellaneous guest-helpful details in ai_general_notes when they do not fit a dedicated field.",
      "Create FAQs only when the source contains a reusable guest question and a clear answer, or when an instruction can naturally become a reusable FAQ.",
      "Return null or omit fields that are not supported by evidence in the source.",
    ].join("\n"),
    messages: [
      {
        role: "user",
        content: propertyImportContent(payload, document),
      },
    ],
  });

  sendJson(response, 200, {
    ...result.object,
    audit: {
      model: gatewayModelId(),
      token_usage: result.usage,
    },
  });
}

async function handleTranslate(payload: any, response: ServerResponse) {
  if (!gatewayConfigured()) {
    sendJson(response, 503, { error: "AI gateway is not configured" });
    return;
  }

  const result = await generateObject({
    model: gatewayModel(),
    schema: TranslationSchema,
    schemaName: "AylaTranslation",
    system: [
      "You translate short-term rental guest/host messages for Ayla Manager.",
      "Translate the text into target_language.",
      "Preserve concrete facts exactly: times, dates, names, addresses, WiFi names, passwords, codes, URLs, phone numbers, prices, and proper nouns.",
      "Do not add new information, apologies, explanations, signatures, or formatting that was not present.",
      "Keep the tone natural, warm, and concise.",
      "Return only the translated text in translated_text.",
    ].join("\n"),
    prompt: JSON.stringify({
      source_language: payload?.source_language,
      target_language: payload?.target_language,
      text: payload?.text,
      context: payload?.context,
    }),
  });

  sendJson(response, 200, {
    ...result.object,
    audit: {
      model: gatewayModelId(),
      token_usage: result.usage,
    },
  });
}

function propertyImportContent(payload: any, document: any) {
  const parts: any[] = [
    {
      type: "text",
      text: JSON.stringify({
        account: payload?.account,
        current_property: payload?.property,
        document: {
          filename: document?.filename,
          content_type: document?.content_type,
          kind: document?.kind,
          extracted_text: document?.text,
        },
      }),
    },
  ];

  if (document?.base64 && document?.content_type?.startsWith("image/")) {
    parts.push({
      type: "image",
      image: document.base64,
      mediaType: document.content_type,
    });
  } else if (document?.base64 && document?.content_type === "application/pdf") {
    parts.push({
      type: "file",
      data: document.base64,
      filename: document.filename || "property-information.pdf",
      mediaType: "application/pdf",
    });
  }

  return parts;
}

function fallbackDecision(payload: any) {
  const guestText = payload?.guest_message || "";
  const guestLanguage = fallbackGuestLanguage(guestText, payload?.guest_language_fallback);
  const ownerLanguage = payload?.owner_language || payload?.owner_instructions?.ai_preferred_language || "es";
  return {
    outcome: "escalate",
    decision: "escalate",
    language: guestLanguage,
    message_body: safeAckFor(guestText, guestLanguage),
    intent_summary: "AI service fallback",
    detected_intents: [
      {
        type: "unknown",
        status: "escalated",
      },
    ],
    used_source_ids: [],
    evidence_ids: [],
    required_capabilities: [],
    proposed_action: null,
    confidence: 0.25,
    escalation: {
      required: true,
      reason_code: "ai_service_fallback",
      summary_for_host: ownerText(
        ownerLanguage,
        "El huésped hizo una pregunta que el servicio de IA no pudo responder.",
        "The guest asked a question the AI service could not answer.",
      ),
    },
    escalation_required: true,
    escalation_reason: "ai_service_fallback",
    sensitive_info_used: false,
    missing_information: [payload?.guest_message || "guest_message"],
    safety_flags: ["fallback"],
  };
}

function closureDecision(payload: any) {
  const guestText = payload?.guest_message || "";
  const guestLanguage = fallbackGuestLanguage(guestText, payload?.guest_language_fallback);

  return {
    outcome: "no_reply",
    decision: "no_reply",
    language: guestLanguage,
    message_body: null,
    intent_summary: "Conversational closure or acknowledgement",
    detected_intents: [
      {
        type: "conversational_closure",
        status: "answered",
      },
    ],
    used_source_ids: [],
    evidence_ids: [],
    required_capabilities: [],
    proposed_action: null,
    confidence: 1,
    escalation: {
      required: false,
      reason_code: null,
      summary_for_host: null,
    },
    escalation_required: false,
    escalation_reason: null,
    sensitive_info_used: false,
    missing_information: [],
    safety_flags: [],
  };
}

function fallbackGuestLanguage(text: string, persistedLanguage?: string) {
  return text.trim().length > 0
    ? detectLanguage(text)
    : normalizeLanguage(persistedLanguage) || "en";
}

function safeBaseContext(payload: any) {
  return {
    guest_message: payload?.guest_message,
    guest_language_fallback: payload?.guest_language_fallback,
    owner_language: payload?.owner_language,
    guest: payload?.guest,
    property: payload?.property,
    reservation: payload?.reservation,
    owner_instructions: payload?.owner_instructions,
    conversation_history: payload?.conversation_history,
    safety_rules: payload?.safety_rules,
    tool_endpoint: payload?.tool_endpoint,
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

function isConversationalClosure(text?: string) {
  const normalized = normalizeClosureText(text || "");
  return [
    "ok",
    "okay",
    "dale",
    "gracias",
    "muchas gracias",
    "perfecto",
    "bien",
    "entendido",
    "listo",
    "genial",
    "excelente",
    "no gracias",
    "asi esta bien",
    "no gracias asi esta bien",
    "esta bien",
    "todo bien",
    "ok gracias",
    "dale gracias",
    "perfecto gracias",
    "listo gracias",
    "thanks",
    "thank you",
    "no thanks",
    "that is fine",
    "thats fine",
  ].includes(normalized);
}

function normalizeClosureText(text: string) {
  return text
    .toLowerCase()
    .normalize("NFD")
    .replace(/\p{Diacritic}/gu, "")
    .replace(/[^\p{Letter}\p{Number}\s👍]+/gu, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function ownerText(language: string, spanish: string, english: string) {
  return normalizeLanguage(language) === "en" ? english : spanish;
}

async function collectToolResults(payload: any, toolTrace: any[] = [], mandatoryTrace = newToolMandatoryTrace(payload)) {
  if (process.env.AI_TOOLS_ENABLED === "false") {
    mandatoryTrace.should_run_tools = false;
    mandatoryTrace.skip_reason = "ai_tools_disabled";
    return [];
  }

  const initialToolResults = await mandatoryToolResults(payload, toolTrace, mandatoryTrace);
  const result = await generateText({
    model: gatewayModel(),
    system: [
      "You select the minimum read-only Ayla tools needed to answer or classify the guest message.",
      "If the latest guest message is only thanks, ok, no thanks, or a conversational closure, do not call tools and summarize it as no_reply.",
      "property_brain is already loaded and is the source of non-sensitive property knowledge.",
      "Call sensitive_access_info only for WiFi, passwords, keys, access codes, entrance instructions, lockboxes, or other sensitive access details.",
      "Call create_escalation_draft if the evidence is missing, ambiguous after one clarification, or needs owner approval.",
      "Never request arbitrary record IDs. Tools are scoped by the signed decision_context_id.",
      "Do not provide a final guest answer. Return a short retrieval summary after tool calls.",
    ].join("\n"),
    prompt: JSON.stringify(safeBaseContext(payload)),
    tools: buildTools({
      ...(payload?.tool_context || {}),
      tool_endpoint: payload?.tool_endpoint,
    }, toolTrace),
    stopWhen: stepCountIs(3),
  });

  return initialToolResults.concat(result.toolResults.map((toolResult: any) => {
    const row = {
      toolName: toolResult.toolName,
      input: toolResult.input,
      result: toolResult.output,
    };
    if (!toolTrace.some((item) => item.tool_name === toolResult.toolName && JSON.stringify(item.input) === JSON.stringify(toolResult.input))) {
      toolTrace.push(traceToolResult(toolResult.toolName, toolResult.input, toolResult.output, undefined, undefined));
    }
    return row;
  }));
}

async function mandatoryToolResults(payload: any, toolTrace: any[] = [], mandatoryTrace = newToolMandatoryTrace(payload)) {
  const mandatoryStartedAt = Date.now();
  const guestContextInput = {
    query: payload?.guest_message,
  };
  const stayFactsInput = {
    requested_fields: [
      "check_in_time",
      "check_out_time",
      "address",
      "parking",
      "rules",
      "emergency_information",
      "reservation_status",
      "reservation_dates",
    ],
  };
  const propertyBrainInput = {
    guest_message: payload?.guest_message,
    conversation_summary: conversationSummary(payload?.conversation_history),
    limit: 8,
  };

  if (payload?.tool_endpoint?.base_url && payload?.tool_endpoint?.decision_context_id) {
    try {
      return await Promise.all([
        tracedMandatoryRailsTool(payload.tool_endpoint, "guest_context", guestContextInput, toolTrace, mandatoryTrace),
        tracedMandatoryRailsTool(payload.tool_endpoint, "stay_facts", stayFactsInput, toolTrace, mandatoryTrace),
        tracedMandatoryRailsTool(payload.tool_endpoint, "property_brain", propertyBrainInput, toolTrace, mandatoryTrace),
      ]);
    } finally {
      mandatoryTrace.tool_execution_time_ms = Date.now() - mandatoryStartedAt;
    }
  }

  if (payload?.tool_context) {
    markMandatoryAttempt(mandatoryTrace, "guest_context");
    markMandatoryAttempt(mandatoryTrace, "stay_facts");
    markMandatoryAttempt(mandatoryTrace, "property_brain");
    const guestContext = payload.tool_context.guest_context || {
      property: payload.tool_context.property_brain?.property,
      reservation: payload.tool_context.property_brain?.stay,
      public_facts: Object.values(payload.tool_context.safe_property_facts || {}),
      relevant_faqs: payload.tool_context.faqs || [],
      relevant_guides: payload.tool_context.knowledge_blocks || [],
    };
    const stayFacts = payload.tool_context.stay_facts ||
      Object.values(payload.tool_context.safe_property_facts || {}).concat(Object.values(payload.tool_context.reservation_facts || {}));
    const propertyBrain = payload.tool_context.property_brain || payload.tool_context;

    toolTrace.push(traceToolResult("guest_context", guestContextInput, guestContext, undefined, 0));
    toolTrace.push(traceToolResult("stay_facts", stayFactsInput, stayFacts, undefined, 0));
    toolTrace.push(traceToolResult("property_brain", propertyBrainInput, propertyBrain, undefined, 0));
    markMandatoryResult(mandatoryTrace, "guest_context", guestContext);
    markMandatoryResult(mandatoryTrace, "stay_facts", stayFacts);
    markMandatoryResult(mandatoryTrace, "property_brain", propertyBrain);
    mandatoryTrace.tool_execution_time_ms = Date.now() - mandatoryStartedAt;

    return [
      { toolName: "guest_context", input: guestContextInput, result: guestContext },
      { toolName: "stay_facts", input: stayFactsInput, result: stayFacts },
      { toolName: "property_brain", input: propertyBrainInput, result: propertyBrain },
    ];
  }

  mandatoryTrace.skip_reason = missingMandatoryContextReason(payload);
  mandatoryTrace.tool_execution_time_ms = Date.now() - mandatoryStartedAt;
  return [];
}

async function tracedMandatoryRailsTool(
  toolEndpoint: any,
  toolName: MandatoryToolName,
  input: Record<string, unknown>,
  toolTrace: any[],
  mandatoryTrace: ToolMandatoryTrace,
) {
  const startedAt = Date.now();
  markMandatoryAttempt(mandatoryTrace, toolName);

  try {
    const result = await callRailsTool(toolEndpoint, toolName, input);
    const error = classifyMandatoryToolResult(result);
    toolTrace.push(traceToolResult(toolName, input, result, error, Date.now() - startedAt));
    markMandatoryResult(mandatoryTrace, toolName, result, error);

    return {
      toolName,
      input,
      result,
    };
  } catch (error: any) {
    const classifiedError = classifyMandatoryToolException(error);
    toolTrace.push(traceToolResult(toolName, input, null, classifiedError, Date.now() - startedAt));
    markMandatoryResult(mandatoryTrace, toolName, null, classifiedError);
    throw error;
  }
}

function conversationSummary(history: any) {
  if (!Array.isArray(history)) return "";

  return history
    .slice(-6)
    .map((message: any) => `${message?.sender || "unknown"}: ${message?.body || ""}`)
    .filter((line: string) => line.trim().length > 0)
    .join("\n");
}

function buildTools(toolContext: any, toolTrace: any[] = []) {
  const remoteTools = buildRemoteTools(toolContext?.tool_endpoint, toolTrace);
  if (remoteTools) return remoteTools;

  return {
    guest_context: {
      description: "Get scoped guest, reservation, language, property, and authorization context for this conversation.",
      inputSchema: z.object({
        query: z.string().optional(),
      }),
      execute: async (input: { query?: string }) => {
        const result = toolContext.guest_context || {
          property: toolContext.property_brain?.property,
          reservation: toolContext.property_brain?.stay,
          public_facts: Object.values(toolContext.safe_property_facts || {}),
        };
        toolTrace.push(traceToolResult("guest_context", input, result, undefined, 0));
        return result;
      },
    },
    stay_facts: {
      description: "Get scoped stay and property facts such as check-in, checkout, address, parking, rules, and reservation status.",
      inputSchema: z.object({
        requested_fields: z.array(z.string()).optional(),
      }),
      execute: async (input: { requested_fields?: string[] }) => {
        const result = toolContext.stay_facts ||
          Object.values(toolContext.safe_property_facts || {}).concat(Object.values(toolContext.reservation_facts || {}));
        toolTrace.push(traceToolResult("stay_facts", input, result, undefined, 0));
        return result;
      },
    },
    property_brain: {
      description: "Get compiled, relevant, non-sensitive property facts, reservation status, policies, FAQs, guides, amenities, and approved recommendations for the current guest message.",
      inputSchema: z.object({
        guest_message: z.string().optional(),
        conversation_summary: z.string().optional(),
        limit: z.number().int().min(1).max(20).optional(),
      }),
      execute: async (input: any) => {
        const result = toolContext.property_brain || toolContext;
        toolTrace.push(traceToolResult("property_brain", input, result, undefined, 0));
        return result;
      },
    },
    sensitive_access_info: {
      description: "Get sensitive access information only if Rails authorized it for this guest and reservation window. Includes WiFi passwords, codes, keys, lockbox, and entrance instructions.",
      inputSchema: z.object({
        guest_message: z.string().optional(),
      }),
      execute: async (input: any) => {
        const result = toolContext.sensitive_access_info || { authorized: false, reason: "not_available", sources: [] };
        toolTrace.push(traceToolResult("sensitive_access_info", input, result, undefined, 0));
        return result;
      },
    },
    create_escalation_draft: {
      description: "Create an escalation draft. This does not write to the database; Rails decides whether to create the real alert.",
      inputSchema: z.object({
        category: z.string(),
        urgency: z.string(),
        summary: z.string(),
      }),
      execute: async (input: { category: string; urgency: string; summary: string }) => {
        const result = {
          draft: true,
          ...input,
        };
        toolTrace.push(traceToolResult("create_escalation_draft", input, result, undefined, 0));
        return result;
      },
    },
  };
}

function buildRemoteTools(toolEndpoint: any, toolTrace: any[] = []) {
  if (!toolEndpoint?.base_url || !toolEndpoint?.decision_context_id) return null;

  return {
    guest_context: {
      description: "Get scoped guest, reservation, language, property, and authorization context for this conversation.",
      inputSchema: z.object({
        query: z.string().optional(),
      }),
      execute: async (input: { query?: string }) =>
        tracedRailsTool(toolEndpoint, "guest_context", input, toolTrace),
    },
    stay_facts: {
      description: "Get scoped stay and property facts such as check-in, checkout, address, parking, rules, and reservation status.",
      inputSchema: z.object({
        requested_fields: z.array(z.string()).optional(),
      }),
      execute: async (input: { requested_fields?: string[] }) =>
        tracedRailsTool(toolEndpoint, "stay_facts", input, toolTrace),
    },
    property_brain: {
      description: "Get compiled, relevant, non-sensitive property facts, reservation status, policies, FAQs, guides, amenities, and approved recommendations for the current guest message.",
      inputSchema: z.object({
        guest_message: z.string().optional(),
        conversation_summary: z.string().optional(),
        limit: z.number().int().min(1).max(20).optional(),
      }),
      execute: async (input: { guest_message?: string; conversation_summary?: string; limit?: number }) =>
        tracedRailsTool(toolEndpoint, "property_brain", input, toolTrace),
    },
    sensitive_access_info: {
      description: "Get sensitive access information only if Rails authorized it for this guest and reservation window. Includes WiFi passwords, codes, keys, lockbox, and entrance instructions.",
      inputSchema: z.object({
        guest_message: z.string().optional(),
      }),
      execute: async (input: { guest_message?: string }) =>
        tracedRailsTool(toolEndpoint, "sensitive_access_info", input, toolTrace),
    },
    create_escalation_draft: {
      description: "Create an escalation draft. This does not write to the database; Rails decides whether to create the real alert.",
      inputSchema: z.object({
        category: z.string(),
        urgency: z.string(),
        summary: z.string(),
      }),
      execute: async (input: { category: string; urgency: string; summary: string }) =>
        tracedRailsTool(toolEndpoint, "escalation_draft", input, toolTrace),
    },
  };
}

async function tracedRailsTool(toolEndpoint: any, toolName: string, input: Record<string, unknown>, toolTrace: any[]) {
  const startedAt = Date.now();
  try {
    const result = await callRailsTool(toolEndpoint, toolName, input);
    toolTrace.push(traceToolResult(toolName, input, result, result?.error, Date.now() - startedAt));
    return result;
  } catch (error: any) {
    toolTrace.push(traceToolResult(toolName, input, null, error?.message || String(error), Date.now() - startedAt));
    throw error;
  }
}

function traceToolResult(toolName: string, input: any, result: any, error?: any, latencyMs?: number) {
  return {
    tool_name: toolName,
    timestamp: new Date().toISOString(),
    input,
    output_summary: summarizeToolOutput(result),
    error: error || null,
    latency_ms: latencyMs ?? null,
  };
}

function newToolMandatoryTrace(payload: any): ToolMandatoryTrace {
  const closure = isConversationalClosure(payload?.guest_message);
  const realGuestMessage = Boolean(payload?.guest_message?.trim()) && !closure;
  const serviceToken = process.env.AI_SERVICE_TOKEN || "";

  return {
    message_received: payload?.guest_message || null,
    is_real_guest_message: realGuestMessage,
    should_run_tools: !closure && process.env.AI_TOOLS_ENABLED !== "false",
    skip_reason: null,
    decision_context_id_present: Boolean(payload?.tool_endpoint?.decision_context_id),
    tool_endpoint_present: Boolean(payload?.tool_endpoint?.base_url),
    tool_endpoint_origin: safeUrlOrigin(payload?.tool_endpoint?.base_url),
    authorization_configured: Boolean(serviceToken),
    authorization_source: "AI_SERVICE_TOKEN",
    authorization_scheme: "Bearer",
    authorization_header_sent: Boolean(serviceToken),
    token_has_surrounding_whitespace: serviceToken.length > 0 && serviceToken !== serviceToken.trim(),
    token_wrapped_in_quotes: isWrappedInQuotes(serviceToken),
    guest_context: emptyMandatoryToolStatus(),
    stay_facts: emptyMandatoryToolStatus(),
    property_brain: emptyMandatoryToolStatus(),
    tool_execution_time_ms: null,
    final_tools: [],
  };
}

function emptyMandatoryToolStatus(): MandatoryToolStatus {
  return { attempted: false, success: false, error: null };
}

function safeUrlOrigin(value?: string) {
  if (!value) return null;

  try {
    return new URL(value).origin;
  } catch {
    return "invalid_url";
  }
}

function isWrappedInQuotes(value: string) {
  return value.length >= 2 && (
    (value.startsWith('"') && value.endsWith('"')) ||
    (value.startsWith("'") && value.endsWith("'"))
  );
}

function markMandatoryAttempt(trace: ToolMandatoryTrace, toolName: MandatoryToolName) {
  trace[toolName].attempted = true;
}

function markMandatoryResult(trace: ToolMandatoryTrace, toolName: MandatoryToolName, result: any, error?: string | null) {
  trace[toolName].success = !error && !result?.error;
  trace[toolName].error = error || (result?.error ? String(result.error) : null);
}

function missingMandatoryContextReason(payload: any) {
  if (!payload?.tool_endpoint?.base_url && !payload?.tool_context) return "missing_tool_endpoint_and_tool_context";
  if (!payload?.tool_endpoint?.base_url) return "missing_tool_endpoint_base_url";
  if (!payload?.tool_endpoint?.decision_context_id) return "missing_decision_context_id";
  return "mandatory_tool_context_unavailable";
}

function classifyMandatoryToolResult(result: any) {
  if (!result?.error) return null;
  if ([401, 403].includes(Number(result.status))) return `authorization_failed:http_${result.status}`;
  if ([404, 410, 422].includes(Number(result.status))) return `decision_context_or_endpoint_failed:http_${result.status}`;
  return `${result.error}:http_${result.status || "unknown"}`;
}

function classifyMandatoryToolException(error: any) {
  if (error?.name === "AbortError" || error?.name === "TimeoutError") return "tool_timeout";
  if (error instanceof SyntaxError) return "response_parsing_failed";
  if (error?.cause?.code) return `http_transport_failed:${error.cause.code}`;
  return `tool_execution_failed:${error?.message || String(error)}`;
}

function finalizeToolMandatoryTrace(trace: ToolMandatoryTrace, toolTrace: any[]) {
  trace.final_tools = toolTrace.map((tool) => ({
    tool_name: tool.tool_name,
    attempted_at: tool.timestamp,
    success: !tool.error,
    error: tool.error || null,
    latency_ms: tool.latency_ms ?? null,
  }));
  return {
    message_received: trace.message_received,
    is_real_guest_message: trace.is_real_guest_message,
    should_run_tools: trace.should_run_tools,
    skip_reason: trace.skip_reason,
    decision_context_id_present: trace.decision_context_id_present,
    tool_endpoint_present: trace.tool_endpoint_present,
    tool_endpoint_origin: trace.tool_endpoint_origin,
    authorization_configured: trace.authorization_configured,
    authorization_source: trace.authorization_source,
    authorization_scheme: trace.authorization_scheme,
    authorization_header_sent: trace.authorization_header_sent,
    token_has_surrounding_whitespace: trace.token_has_surrounding_whitespace,
    token_wrapped_in_quotes: trace.token_wrapped_in_quotes,
    guest_context_attempted: trace.guest_context.attempted,
    guest_context_success: trace.guest_context.success,
    guest_context_error: trace.guest_context.error,
    stay_facts_attempted: trace.stay_facts.attempted,
    stay_facts_success: trace.stay_facts.success,
    stay_facts_error: trace.stay_facts.error,
    property_brain_attempted: trace.property_brain.attempted,
    property_brain_success: trace.property_brain.success,
    property_brain_error: trace.property_brain.error,
    tool_execution_time: trace.tool_execution_time_ms,
    final_tools: trace.final_tools,
  };
}

function emitToolMandatoryTrace(trace: ToolMandatoryTrace, toolTrace: any[]) {
  const finalized = finalizeToolMandatoryTrace(trace, toolTrace);
  console.log("TOOL_MANDATORY_TRACE", JSON.stringify(finalized));
}

function withToolMandatoryAudit(decision: any, toolTrace: any[], mandatoryTrace: ToolMandatoryTrace) {
  return {
    ...decision,
    audit: {
      ...(decision?.audit || {}),
      final_decision_source: {
        model: false,
        retry_model: false,
        grounded_override: false,
        fallback: true,
      },
      tool_calls: toolTrace,
      tool_mandatory_trace: finalizeToolMandatoryTrace(mandatoryTrace, toolTrace),
    },
  };
}

function summarizeToolOutput(result: any) {
  if (!result) return null;
  return {
    evidence_ids: collectEvidenceIds(result),
    result_count: Array.isArray(result) ? result.length : undefined,
    keys: typeof result === "object" && !Array.isArray(result) ? Object.keys(result).slice(0, 20) : undefined,
    preview: JSON.stringify(result).slice(0, 1200),
  };
}

function buildModelInputTrace(
  payload: any,
  toolResults: any[],
  evidenceCatalog: any[],
  extra: Record<string, unknown> = {},
) {
  const firstEvidenceIds = evidenceCatalog
    .map((entry) => entry?.evidence_id)
    .filter(Boolean)
    .slice(0, 20);
  const toolResultKeys = toolResults.map((item) => ({
    toolName: item?.toolName,
    result_keys: item?.result && typeof item.result === "object" && !Array.isArray(item.result)
      ? Object.keys(item.result).slice(0, 20)
      : [],
    result_type: Array.isArray(item?.result) ? "array" : typeof item?.result,
  }));

  return {
    tool_results_present: toolResults.length > 0,
    tool_results_count: toolResults.length,
    tool_results_keys: toolResultKeys,
    evidence_catalog_size: evidenceCatalog.length,
    first_evidence_ids: firstEvidenceIds,
    includes_property_check_in_time: firstEvidenceIds.includes("property.check_in_time") ||
      evidenceCatalog.some((entry) => entry?.evidence_id === "property.check_in_time"),
    tool_context_present: Boolean(payload?.tool_context),
    tool_context_mode: payload?.tool_context ? "inline_legacy_context" : "rails_tool_endpoint_context",
    tool_endpoint_present: Boolean(payload?.tool_endpoint?.base_url && payload?.tool_endpoint?.decision_context_id),
    guest_message_present: Boolean(payload?.guest_message),
    ...extra,
  };
}

function searchSources(sources: any[], query: string, topic?: string) {
  const words = searchTokens(query);

  return sources
    .map((source) => {
      const haystack = [source.label, source.value, source.category, source.source_type].join(" ").toLowerCase();
      const sourceWords = searchTokens(haystack);
      if (!sourceMatchesIntent(words, sourceWords)) return null;

      const score = words.reduce((total, word) => {
        if (sourceWords.includes(word)) return total + 3;
        if (word.length >= 5 && sourceWords.some((sourceWord) => sourceWord.length >= 5 && editDistanceAtMostOne(word, sourceWord))) {
          return total + 2;
        }
        return total;
      }, topic && haystack.includes(topic) ? 1 : 0);
      return { source, score };
    })
    .filter((item): item is { source: any; score: number } => item !== null)
    .filter((item) => item.score >= minimumSearchScore(words))
    .sort((a, b) => b.score - a.score)
    .map((item) => item.source);
}

function searchTokens(value: string) {
  const stopwords = new Set([
    "como", "cual", "cuando", "donde", "para", "porque", "quien", "algo",
    "esta", "este", "esto", "tengo", "quiero", "puedo",
    "what", "where", "when", "with", "this", "that", "there", "please",
    "hora", "horario", "horarios", "hours", "time", "times", "saber",
    "decis", "decime", "dirias", "podrias", "pasarias",
  ]);

  const tokens = value
    .toLowerCase()
    .normalize("NFD")
    .replace(/\p{Diacritic}/gu, "")
    .replace(/\bq\b/g, " que ")
    .split(/[^a-z0-9]+/i)
    .filter((word) => word.length >= 4 && !stopwords.has(word));

  return Array.from(new Set(expandSearchTokens(tokens)));
}

function expandSearchTokens(tokens: string[]) {
  const expanded = [...tokens];
  if (intersects(tokens, ["llego", "llegar", "guia", "ubicacion", "direccion", "acceder", "acceso", "bajar", "bajo", "subir", "edificio", "maps", "mapa", "route", "directions"])) {
    expanded.push("direction");
  }
  if (intersects(tokens, ["pileta", "piscina", "pool"])) expanded.push("pool");
  if (intersects(tokens, ["lavadero", "lavarropas", "laundry", "laundromat", "washing", "washer"])) expanded.push("laundry");
  if (intersects(tokens, ["invitar", "invitados", "visita", "visitas", "gente", "amigos", "guests", "visitors", "visitor", "friends", "bring"])) {
    expanded.push("visitors", "permission");
  }
  if (intersects(tokens, ["permiso", "permitido", "permitir", "allowed", "allow", "approve", "approved"])) {
    expanded.push("permission");
  }
  if (intersects(tokens, ["checkin", "entrada", "ingreso", "arrival", "arrive", "llegar"])) expanded.push("checkin");
  if (intersects(tokens, ["checkout", "salida", "salir", "leave", "departure"])) expanded.push("checkout");
  return expanded;
}

function sourceMatchesIntent(queryTokens: string[], sourceTokens: string[]) {
  if (intersects(queryTokens, ["visitors", "permission"]) && !intersects(sourceTokens, ["visitors", "permission"])) {
    return false;
  }

  return true;
}

function minimumSearchScore(tokens: string[]) {
  const meaningful = tokens.filter((token) => !["direction", "pool", "laundry", "visitors", "permission", "checkin", "checkout"].includes(token));
  return meaningful.length >= 2 ? 6 : 3;
}

function intersects(left: string[], right: string[]) {
  return left.some((item) => right.includes(item));
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
    evidence_ids: collectEvidenceIds(item.result),
    source_ids: Array.isArray(item.result)
      ? item.result.map((source: any) => source?.id || source?.source_id).filter(Boolean)
      : [item.result?.id || item.result?.source_id].filter(Boolean),
  }));
}

function collectEvidenceIds(result: any): string[] {
  if (!result) return [];
  if (Array.isArray(result)) {
    return result.flatMap((item) => collectEvidenceIds(item));
  }
  if (typeof result !== "object") return [];

  const own = [result.id, result.evidence_id, result.source_id].filter(Boolean).map(canonicalEvidenceId);
  const nested = Object.values(result).flatMap((value) => collectEvidenceIds(value));
  return Array.from(new Set([...own, ...nested]));
}
