import { createServer } from "node:http";
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
  if (request.method !== "POST" || request.url !== "/decide") {
    response.writeHead(404, { "content-type": "application/json" });
    response.end(JSON.stringify({ error: "Not found" }));
    return;
  }

  const body = await readBody(request);
  const payload = JSON.parse(body);

  if (!process.env.OPENAI_API_KEY) {
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify(fallbackDecision(payload)));
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

  response.writeHead(200, { "content-type": "application/json" });
  response.end(JSON.stringify(result.object));
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

function fallbackDecision(payload: any) {
  return {
    response_text:
      "I do not have that information yet. I will check with your host and get back to you shortly.",
    should_reply: true,
    confidence: 0.25,
    escalation_required: true,
    alert_type: "unknown_question",
    alert_title: "Question needs host input",
    alert_description: payload?.guest_message || "Guest asked a question the AI could not answer.",
    suggested_owner_action: "Add the answer to the property guide or FAQ, then reply to the guest.",
  };
}
