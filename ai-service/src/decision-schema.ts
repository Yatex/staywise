import { z } from "zod";
import { sanitizeGuestVisibleText } from "./guest-message-sanitizer.js";

export const DecisionSchema = z.preprocess(normalizeDecisionInput, z.object({
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
  safe_fallback_response: z.string().nullable().default(null),
  intent_summary: z.string(),
  detected_intents: z.array(z.object({
    type: z.string(),
    status: z.enum([
      "answered",
      "answered_with_inference",
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
        "guest_request",
        "request_extra_item",
        "request_service",
        "request_extra_bed",
        "request_food_or_drink",
        "request_transport",
        "request_other",
        "none",
      ]),
      payload: z.record(z.unknown()).default({}),
    })
    .nullable()
    .default(null),
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
}).strict());

export function recoverDecisionFromRawText(rawText: unknown) {
  const parsed = parseJsonFromRawText(rawText);
  if (!parsed.ok) return parsed;

  const validation = DecisionSchema.safeParse(parsed.value);
  if (!validation.success) {
    return {
      ok: false as const,
      error: "schema_validation_failed",
      issues: validation.error.issues,
      value: parsed.value,
    };
  }

  return {
    ok: true as const,
    value: validation.data,
  };
}

function normalizeDecisionInput(input: unknown) {
  if (!input || typeof input !== "object" || Array.isArray(input)) return input;

  const value = { ...(input as Record<string, unknown>) };
  const outcome = String(value.outcome || value.decision || "");
  const escalationRequired = value.escalation_required ?? (["escalate", "propose_action"].includes(outcome));

  if (value.outcome == null && value.decision != null) value.outcome = value.decision;
  if (value.message_body == null && value.response_text != null) value.message_body = value.response_text;
  if (typeof value.message_body === "string") value.message_body = sanitizeGuestVisibleText(value.message_body);
  if (value.safe_fallback_response === undefined && value.safe_response !== undefined) {
    value.safe_fallback_response = value.safe_response;
  }
  if (typeof value.safe_fallback_response === "string") {
    value.safe_fallback_response = sanitizeGuestVisibleText(value.safe_fallback_response);
  }
  delete value.decision;
  delete value.response_text;
  delete value.safe_response;
  if (value.proposed_action === undefined) value.proposed_action = null;
  if (value.escalation_required === undefined) value.escalation_required = Boolean(escalationRequired);
  if (value.escalation_reason === undefined) value.escalation_reason = null;

  const escalation = value.escalation && typeof value.escalation === "object" && !Array.isArray(value.escalation)
    ? { ...(value.escalation as Record<string, unknown>) }
    : {};

  value.escalation = {
    required: Boolean(escalation.required ?? value.escalation_required),
    reason_code: escalation.reason_code ?? escalation.category ?? null,
    summary_for_host: escalation.summary_for_host ?? escalation.summary ?? null,
  };

  return value;
}

function parseJsonFromRawText(rawText: unknown) {
  if (rawText == null) {
    return { ok: false as const, error: "raw_text_missing" };
  }

  const text = String(rawText).trim();
  for (const candidate of jsonCandidates(text)) {
    try {
      return {
        ok: true as const,
        value: JSON.parse(candidate),
      };
    } catch {
      // Try the next conservative extraction.
    }
  }

  return { ok: false as const, error: "json_parse_failed" };
}

function jsonCandidates(text: string) {
  const withoutFence = text
    .replace(/^```(?:json)?\s*/i, "")
    .replace(/\s*```$/i, "")
    .trim();

  const candidates = [text, withoutFence];
  const firstBrace = withoutFence.indexOf("{");
  const lastBrace = withoutFence.lastIndexOf("}");
  if (firstBrace >= 0 && lastBrace > firstBrace) {
    candidates.push(withoutFence.slice(firstBrace, lastBrace + 1));
  }

  return Array.from(new Set(candidates.filter(Boolean)));
}
