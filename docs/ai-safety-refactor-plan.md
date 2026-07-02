# AI tool-first WhatsApp flow

## Goal

WhatsApp answers should be interpreted and drafted by the AI service, while Rails remains the authority for tenancy, property scope, reservation authorization, sensitive data, policies, alert creation, actions, logging, and outbound WhatsApp delivery.

The AI service must not access the database, send WhatsApp messages, create alerts, or execute host-facing actions.

## Flow

```text
WhatsApp webhook in Rails
  -> identify account, property, guest, conversation, reservation context
  -> minimal deterministic router
  -> build signed decision_context_id
  -> AI service /decide
  -> AI service calls Rails tools using decision_context_id
  -> AI returns strict decision contract
  -> Rails validates language, evidence, permissions, policies, actions
  -> Rails creates alert/action if needed
  -> Rails sends WhatsApp only after validation
  -> Rails writes AiDecisionLog
```

## Minimal deterministic router

`AI::DeterministicRouter` only handles:

- simple QR/introduction messages;
- simple acknowledgements that do not need a reply;
- explicit human handoff requests;
- emergencies that should not wait for the model.

Questions about WiFi, access, check-in, checkout, directions, recommendations, FAQs, rules, amenities, policies, approvals, ambiguous wording, or multiple intents go to the AI service.

## Signed decision context

Rails issues a short-lived signed `decision_context_id` with:

- account id;
- property id;
- guest id;
- conversation id;
- message id.

Internal tools reject free `conversation_id`, `property_id`, `guest_id`, or reservation flags. Every tool resolves scope through `AI::DecisionContext`.

## Internal tools

All internal tools require:

```json
{ "decision_context_id": "signed-token" }
```

Available endpoints:

- `POST /internal/ai/tools/guest_context`
- `POST /internal/ai/tools/stay_facts`
- `POST /internal/ai/tools/search_property_knowledge`
- `POST /internal/ai/tools/approved_recommendations`
- `POST /internal/ai/tools/access_instructions`
- `POST /internal/ai/tools/property_policy`
- `POST /internal/ai/tools/escalation_draft`

`guest_context` is the mandatory first context. It returns safe property/reservation context, capabilities, relevant FAQs/guides, public facts, and structured evidence.

Sensitive tools such as `access_instructions` are still authorized by Rails at call time.

## Evidence

Tools return structured evidence with:

- `evidence_id`;
- `source_type`;
- `source_id`;
- `field`;
- `value` or `excerpt`;
- `scope`;
- `updated_at`.

Examples:

- `property.check_in_time`
- `property.check_out_time`
- `property.wifi_password`
- `reservation.reservation_status`
- `faq.123`
- `guide.456`
- `recommendation.789`
- `policy.late_checkout`

Rails validates that cited evidence exists, belongs to the same property/reservation scope, is relevant to the guest question, and is authorized for sensitive data.

## AI service contract

`POST /decide` returns a strict contract:

```json
{
  "decision": "reply",
  "language": "es",
  "message_body": "El check-in es a las 15:00.",
  "intent_summary": "Pregunta por horario de check-in",
  "detected_intents": [
    { "type": "check_in", "status": "answered" }
  ],
  "evidence_ids": ["property.check_in_time"],
  "required_capabilities": [],
  "proposed_action": null,
  "escalation": {
    "required": false,
    "reason_code": null,
    "summary_for_host": null
  },
  "missing_information": [],
  "safety_flags": [],
  "confidence": 0.95
}
```

The AI service must not include arbitrary fields in `/decide`.

## Rails validation

`AI::DecisionValidator` blocks replies when:

- outcome is invalid;
- reply language does not match the guest message;
- factual reply has no evidence;
- evidence id does not exist;
- evidence belongs to another property;
- evidence is irrelevant to the latest guest question;
- sensitive WiFi/access evidence is not authorized;
- the reply appears to approve a sensitive/commercial action;
- the reply says the host was notified without escalation/action;
- detected intents have invalid statuses.

If validation fails, Rails rejects the AI text, records the reason, and falls back to a safe escalation.

## Honest fallbacks

Rails only says that the host was notified when an alert/action is actually created. If escalation is disabled and no alert exists, the WhatsApp reply says:

```text
No tengo esa información confirmada en este momento. Puedo pedirle al anfitrión que la revise.
```

## Observability

Every decision attempts to write `AiDecisionLog` with:

- original message/conversation/property/guest;
- route;
- final decision;
- language;
- detected intents;
- evidence ids;
- missing information;
- safety flags;
- validator result and rejection reason;
- escalation/reply candidates;
- latency/model;
- raw audit payload.

## Feature flags

- `AI_TOOL_FIRST_FLOW_ENABLED`: enables remote tool-first AI flow. Defaults to true.
- `AI_SAFE_ROUTER_ENABLED`: enables the minimal deterministic router. Defaults to true.
- `AI_EVIDENCE_REQUIRED`: requires evidence for factual replies. Defaults to true.
- `AI_CONSERVATIVE_FALLBACK_ENABLED`: uses safe fallback when the AI service is unavailable. Defaults to true.
- `AI_TOOLS_ENABLED`: enables AI service tool calls. Defaults to true.
