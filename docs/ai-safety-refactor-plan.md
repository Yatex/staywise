# AI safety refactor plan

## Goals

- Keep Rails as the source of truth for account, property, guest, reservation, authorization, alerts, and outbound WhatsApp delivery.
- Stop sending full property context to the model by default.
- Require validated evidence for AI-generated replies.
- Handle emergencies, exact safe facts, sensitive facts, and sensitive requests deterministically before AI.
- Keep the existing WhatsApp flow, models, alert creation, and local development behavior compatible.

## Incremental implementation

1. Add a safer Rails decision contract while preserving legacy fields used by the current handler.
2. Add deterministic Rails services:
   - `AI::SafetyConfig` for feature flags.
   - `AI::ReservationAuthorization` for date/window checks.
   - `AI::SourceRegistry` for scoped evidence lookup and safe fact exposure.
   - `AI::DeterministicRouter` for emergency, exact fact, sensitive fact, and sensitive request handling.
   - `AI::DecisionValidator` for evidence, scope, confidence, and sensitive approval checks.
3. Refactor `AI::ContextBuilder` to build a minimal prompt payload plus an internal `tool_context` for server-side scoped tool calls.
4. Refactor `AI::DecisionService` so the flow is:
   - deterministic router
   - optional Node AI service
   - Rails validation
   - conservative fallback or escalation if needed
5. Update the Node AI service with a stricter Zod decision schema and restricted server-side tools. The model receives only safe base context and tool results scoped by Rails.
6. Add tests for deterministic exact facts, emergency handling, sensitive requests, evidence rejection, invalid evidence rejection, and safe fallback.
7. Update README environment documentation.

## Feature flags

- `AI_SAFE_ROUTER_ENABLED`: enables deterministic routing before AI. Defaults to enabled.
- `AI_EVIDENCE_REQUIRED`: rejects AI replies without validated evidence. Defaults to enabled.
- `AI_CONSERVATIVE_FALLBACK_ENABLED`: avoids broad keyword fallback when AI is unavailable. Defaults to enabled.
- `AI_TOOLS_ENABLED`: enables Node service server-side scoped tool retrieval. Defaults to enabled in Node.

## Migration note

No database migration is required in this phase. Audit data is written into Rails logs and decision metadata on AI messages where a reply is actually sent. Future admin-facing audit views can add a dedicated `ai_audit_events` table without changing this decision contract.
