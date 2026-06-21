import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { generateObject } from "ai";
import { openai } from "@ai-sdk/openai";
import { z } from "zod";

const DecisionSchema = z.object({
  response_text: z.string(),
  should_reply: z.boolean(),
  confidence: z.number().min(0).max(1),
  escalation_required: z.boolean(),
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
    .nullable(),
  alert_title: z.string().nullable(),
  alert_description: z.string().nullable(),
  suggested_owner_action: z.string().nullable(),
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

    if (!process.env.OPENAI_API_KEY) {
      sendJson(response, 200, fallbackDecision(payload));
      return;
    }

    const result = await generateObject({
      model: openai(process.env.AI_MODEL || "gpt-5-mini"),
      schema: DecisionSchema,
      system: [
        "You are Staywise, an AI guest assistant for short-term rentals.",
        "Answer only from owner-provided property information, FAQs, recommendations, and instructions.",
        "Do not invent property rules, prices, availability, refunds, or policies.",
        "If information is missing or approval is needed, say you will check with the host and create an alert.",
        "Keep replies friendly, helpful, concise, and in the guest language when possible.",
      ].join("\n"),
      prompt: JSON.stringify(payload),
    });

    sendJson(response, 200, result.object);
  } catch (error) {
    console.error("[ai-service]", error);
    sendJson(response, 500, {
      error: "AI decision failed",
      ...fallbackDecision({ guest_message: "No se pudo procesar la consulta del huésped." }),
    });
  }
});

server.listen(Number(process.env.PORT || 8787), () => {
  console.log(`Staywise AI service listening on ${process.env.PORT || 8787}`);
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

function fallbackDecision(payload: any) {
  return {
    response_text:
      "Todavía no tengo esa información. Voy a consultarlo con el anfitrión y te respondo en breve.",
    should_reply: true,
    confidence: 0.25,
    escalation_required: true,
    alert_type: "unknown_question",
    alert_title: "Pregunta pendiente del anfitrión",
    alert_description: payload?.guest_message || "El huésped hizo una pregunta que la IA no pudo responder.",
    suggested_owner_action: "Agregá la respuesta a la guía o FAQ de la propiedad y luego respondé al huésped.",
  };
}
