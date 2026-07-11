import { z } from "zod";
import { sanitizeGuestVisibleText } from "./guest-message-sanitizer.js";

const AttachmentSchema = z.object({
  type: z.enum(["video", "image", "document"]),
  evidence_id: z.string().min(1),
}).strict();

const PublicDecisionSchema = z.object({
  action: z.enum(["reply", "clarify", "create_owner_task"]),
  owner_task_kind: z.enum(["request", "inquiry"]).nullable().default(null),
  language: z.string().min(2),
  message: z.string().min(1),
  task_summary: z.string().nullable().default(null),
  answer_confidence: z.number().min(0).max(100),
  evidence_ids: z.array(z.string()).default([]),
  attachments: z.array(AttachmentSchema).default([]),
}).strict().superRefine((decision, context) => {
  if (decision.action === "create_owner_task" && !decision.owner_task_kind) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ["owner_task_kind"], message: "owner_task_kind is required" });
  }
  if (decision.action !== "create_owner_task" && decision.owner_task_kind) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ["owner_task_kind"], message: "owner_task_kind is only valid for create_owner_task" });
  }
});

// generateObject sees the small public contract. The transform keeps the
// existing grounded-decision internals stable during the contract migration.
export const DecisionSchema = PublicDecisionSchema.transform(toInternalDecision);

export function toPublicDecision(decision: any) {
  const action = publicAction(decision);
  const ownerTaskKind = action === "create_owner_task"
    ? (decision?.owner_task_kind === "request" ? "request" : "inquiry")
    : null;
  const scores = decision?.audit?.grounded_decision_builder?.decision_scores || {};
  const answerConfidence = score100(
    decision?.answer_confidence ?? scores.answer_confidence ?? Number(decision?.confidence || 0) * 100,
  );

  return {
    action,
    owner_task_kind: ownerTaskKind,
    language: String(decision?.language || "").trim() || "es",
    message: sanitizeGuestVisibleText(decision?.message || decision?.message_body || decision?.response_text || ""),
    task_summary: action === "create_owner_task"
      ? String(decision?.task_summary || decision?.intent_summary || decision?.escalation?.summary_for_host || "").trim() || null
      : null,
    answer_confidence: answerConfidence,
    evidence_ids: uniqueStrings(decision?.evidence_ids || decision?.used_source_ids),
    attachments: normalizeAttachments(decision?.attachments),
  };
}

export function recoverDecisionFromRawText(rawText: unknown) {
  const parsed = parseJsonFromRawText(rawText);
  if (!parsed.ok) return parsed;

  const validation = DecisionSchema.safeParse(parsed.value);
  if (!validation.success) {
    return { ok: false as const, error: "schema_validation_failed", issues: validation.error.issues, value: parsed.value };
  }
  return { ok: true as const, value: validation.data };
}

function toInternalDecision(value: z.infer<typeof PublicDecisionSchema>) {
  const outcome = value.action === "clarify"
    ? "ask_clarifying_question"
    : value.action === "create_owner_task" ? "propose_action" : "reply";
  const escalationRequired = value.action === "create_owner_task";

  return {
    ...value,
    outcome,
    decision: outcome,
    language: value.language,
    message_body: sanitizeGuestVisibleText(value.message),
    response_text: sanitizeGuestVisibleText(value.message),
    intent_summary: value.task_summary || value.action,
    detected_intents: [],
    used_source_ids: value.evidence_ids,
    required_capabilities: escalationRequired ? ["owner_attention"] : [],
    proposed_action: escalationRequired ? { type: "guest_request", payload: {} } : null,
    escalation: {
      required: escalationRequired,
      reason_code: value.owner_task_kind,
      summary_for_host: value.task_summary,
    },
    escalation_required: escalationRequired,
    escalation_reason: escalationRequired ? value.owner_task_kind : null,
    sensitive_info_used: false,
    missing_information: [],
    safety_flags: [],
    confidence: value.answer_confidence / 100,
  };
}

function publicAction(decision: any) {
  if (decision?.action === "clarify" || decision?.outcome === "ask_clarifying_question") return "clarify";
  if (decision?.action === "create_owner_task" || decision?.owner_task_kind) return "create_owner_task";
  if (["escalate", "propose_action"].includes(String(decision?.outcome || decision?.decision))) return "create_owner_task";
  return "reply";
}

function normalizeAttachments(value: unknown) {
  if (!Array.isArray(value)) return [];
  return value.filter((item) => item && typeof item === "object").map((item: any) => ({
    type: String(item.type || ""),
    evidence_id: String(item.evidence_id || ""),
  })).filter((item) => ["video", "image", "document"].includes(item.type) && item.evidence_id);
}

function uniqueStrings(value: unknown) {
  return Array.from(new Set((Array.isArray(value) ? value : []).map(String).filter(Boolean)));
}

function score100(value: unknown) {
  const number = Number(value || 0);
  return Math.max(0, Math.min(100, Math.round(number)));
}

function parseJsonFromRawText(rawText: unknown) {
  if (rawText == null) return { ok: false as const, error: "raw_text_missing" };
  const text = String(rawText).trim();
  for (const candidate of jsonCandidates(text)) {
    try { return { ok: true as const, value: JSON.parse(candidate) }; } catch { /* try next */ }
  }
  return { ok: false as const, error: "json_parse_failed" };
}

function jsonCandidates(text: string) {
  const withoutFence = text.replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/i, "").trim();
  const candidates = [text, withoutFence];
  const firstBrace = withoutFence.indexOf("{");
  const lastBrace = withoutFence.lastIndexOf("}");
  if (firstBrace >= 0 && lastBrace > firstBrace) candidates.push(withoutFence.slice(firstBrace, lastBrace + 1));
  return Array.from(new Set(candidates.filter(Boolean)));
}
