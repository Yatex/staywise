# Ayla AI Architecture Principles

> Current scope: host Copilot. AI-created operational effects and automatic guest delivery are legacy and are not part of the runtime contract.

This document is the architectural source of truth for Ayla Stay / Ayla Manager.

Any AI agent or developer proposing, reviewing, or writing code that touches WhatsApp, AI decisions, tools, evidence, alerts, guests, properties, reservations, or host workflows must read this document before making changes.

If existing code conflicts with this document, the correct direction is to move the code toward this document. Do not use old implementation details as justification for weakening these principles.

## 1. Main Philosophy

Ayla Stay is:

- tool-first;
- evidence-first;
- Rails-authoritative;
- AI-assisted;
- security-first.

The AI is the interpretation and drafting engine.

Rails is the final authority.

The AI may interpret a guest message, decide what information is needed, request tools, draft a reply, draft an escalation, or ask a clarifying question.

Rails must validate, authorize, persist, send, reject, escalate, and audit.

## 2. Tool-First Is Mandatory

The AI must never answer from memory about:

- properties;
- reservations;
- guests;
- any property fact;
- any reservation or guest fact;
- access, arrival, departure, or stay instructions;
- policies, rules, permissions, exceptions, or approvals;
- local recommendations or operational guidance;
- prices, availability, payments, refunds, or commercial terms;
- amenities, appliances, building facilities, or neighborhood information.

The AI must obtain information through tools.

BAD:

```text
I think most rentals allow that.
```

GOOD:

```text
Call the relevant tools.
Answer only using returned source ids / evidence ids.
```

BAD:

```text
This is usually fine in short-term rentals.
```

GOOD:

```text
Search all relevant sources.
If no policy or fact is found, ask the smallest useful clarification or escalate only if human approval is required.
```

## 3. Progressive Information Gathering

The AI's main goal is not to escalate quickly.

The AI's main goal is to resolve the guest's request using all available information before involving the host.

Escalation is the last resort.

Before escalating, the AI must progressively:

1. Search all relevant tools.
2. Retry searches when the first result is not enough.
3. Reformulate queries.
4. Consult other available sources.
5. Combine evidence from multiple tools.
6. Reason using all evidence found.
7. Ask a clarifying question when the guest's request is ambiguous.
8. Ask only for the minimum missing information when the guest must provide something.
9. Explain the known policy when the answer requires host approval, and escalate only the approval decision.

The AI may escalate only when at least one of these is true:

- all relevant tools were used and no sufficient evidence exists;
- a clarifying question would not reasonably resolve the uncertainty;
- the request truly requires human intervention, approval, judgment, or action;
- continuing automatically would create a safety, security, legal, payment, or guest-experience risk.

BAD:

```json
{
  "decision": "escalate",
  "detected_intents": [{ "type": "unknown" }],
  "tools_called": []
}
```

GOOD:

```json
{
  "decision": "ask_clarifying_question",
  "message_body": "¿Te referís al horario para llegar, para salir, o a otra cosa?",
  "tools_called": ["guest_context", "property_brain", "stay_facts"]
}
```

## 4. Evidence First

Every factual claim must be backed by evidence.

The AI cannot:

- assume;
- extrapolate;
- fill gaps;
- answer from common sense;
- reuse unrelated evidence;
- use a source that only partially matches the question;
- cite evidence that was not returned by a tool.

Every factual reply must include source ids / evidence ids returned by tools.

If tools return sufficient evidence to answer the guest's request, the AI must not end as:

- `unknown`;
- `fallback`;
- `escalate`.

The AI must answer using that evidence.

This applies to every evidence source, including:

- property facts;
- guest context;
- property brain;
- FAQs;
- knowledge blocks;
- guides;
- recommendations;
- policies;
- any future tool or knowledge source.

Do not hardcode rules for individual topics or fields. The system must be generic.

The AI must evaluate whether the available evidence is sufficient to answer, regardless of where that evidence came from.

BAD:

```json
{
  "decision": "reply",
  "message_body": "The pool is on floor -1.",
  "evidence_ids": []
}
```

GOOD:

```json
{
  "decision": "reply",
  "message_body": "La pileta está en el piso -1.",
  "used_source_ids": ["faq_123"]
}
```

BAD:

```json
{
  "decision": "reply",
  "message_body": "Western Union is nearby.",
  "used_source_ids": ["recommendation_91"]
}
```

when the guest asked:

```text
What are the laundry hours?
```

The evidence is real but irrelevant, therefore invalid.

GOOD:

```json
{
  "decision": "reply",
  "message_body": "La respuesta debe usar la evidencia relevante encontrada.",
  "evidence_ids": ["returned_evidence_id"]
}
```

## 5. Clarify Before Escalate

When uncertainty can be resolved by asking the guest something, the AI must prefer a clarifying question before escalating to the host.

Clarifying questions must be:

- short;
- specific;
- useful;
- in the guest's language;
- limited to the minimum information needed.

Examples:

```text
Guest: A qué hora puedo ir?
AI: ¿Te referís al horario para llegar, para salir, o a otra cosa?
```

```text
Guest: ¿Puedo entrar antes?
AI: First use tools to check the relevant policy. If approval is required, explain that approval is needed and escalate only that approval request.
```

```text
Guest: No anda.
AI: ¿Qué es exactamente lo que no funciona?
```

```text
Guest: No encuentro la llave.
AI: ¿Dónde estás intentando ingresar o en qué paso te trabaste?
```

BAD:

```json
{
  "decision": "escalate",
  "reason": "ambiguous_question"
}
```

GOOD:

```json
{
  "decision": "ask_clarifying_question",
  "message_body": "Ask one precise question that can unlock the answer."
}
```

## 6. Escalation Is The Last Resort

The AI must behave like a competent human receptionist.

It must try to:

- search;
- reason;
- combine information;
- ask questions;
- resolve.

It must not abandon the conversation at the first difficulty.

An escalation has a cost for the host and creates a worse guest experience.

Escalation is acceptable only when there is no reasonable automated path left, or when the host must genuinely approve, decide, intervene, or act.

Escalations should be narrow:

- escalate the missing approval, not the entire conversation;
- escalate the unresolved detail, not already answered facts;
- include the relevant evidence and the exact reason human input is required.

## 7. Rails Is The Authority

The AI must never:

- send WhatsApp messages;
- create alerts;
- write to the database;
- approve actions;
- authorize access;
- decide permissions;
- confirm payments;
- confirm refunds;
- confirm discounts;
- confirm compensation;
- confirm early check-in;
- confirm late checkout;
- confirm reservation extensions;
- confirm availability;
- confirm visitor permission;
- confirm exceptions.

The AI only proposes.

Rails decides.

BAD:

```json
{
  "decision": "reply",
  "message_body": "Yes, late checkout is approved."
}
```

GOOD:

```json
{
  "decision": "escalate",
  "escalation_reason": "late_checkout_requires_owner_approval",
  "message_body": "Tengo que confirmarlo con el anfitrión antes de asegurártelo."
}
```

Rails then decides whether to create the alert, send the message, or reject the decision.

## 8. Deterministic Router Must Stay Minimal

The `DeterministicRouter` exists only for tiny, safe, non-interpretive cases:

- simple greetings;
- simple thanks;
- simple acknowledgements;
- obvious spam/no-op messages;
- emergencies;
- explicit requests for a human.

The router must not:

- interpret natural language broadly;
- resolve ambiguity;
- answer factual guest questions;
- answer questions about property, stay, reservation, access, policies, guides, recommendations, amenities, facilities, prices, or availability;
- resolve multiple intents;
- replace the AI service;
- become a growing pile of regexes.

BAD:

```ruby
if text.match?(/a que hora puedo ir|puedo llegar|hora/)
  reply_with_check_in_time
end
```

GOOD:

```text
Send the message to the AI service.
The AI uses tools, evidence, progressive information gathering, and clarification when needed.
Rails validates the result.
```

## 9. Ambiguity Belongs To The AI

Ambiguity must be resolved by the AI, not by adding more router rules.

Example:

```text
a qué hora puedo ir
```

This could mean:

- arrival time;
- earliest arrival;
- luggage drop-off;
- building access time;
- appointment time;
- departure time in a confused phrasing.

Do not:

- add regex;
- add heuristics;
- assume check-in;
- escalate immediately;
- answer with a random fact.

Do:

- send it to the AI service;
- let the AI inspect context through tools;
- ask a clarifying question if needed;
- only escalate if clarification cannot resolve it or owner approval is required.

BAD:

```text
Answering with one possible interpretation without confirming it.
```

GOOD:

```text
Ask the smallest clarification needed to disambiguate the request.
```

## 10. Signed Context Only

Internal AI tools must never accept raw:

- `property_id`;
- `guest_id`;
- `reservation_id`;
- `conversation_id`;
- user-supplied account ids;
- arbitrary record ids as authority.

Tools must accept only:

```json
{
  "decision_context_id": "signed-context-token"
}
```

Rails resolves the real context from the signed token.

BAD:

```json
{
  "property_id": 123,
  "guest_id": 456,
  "query": "wifi"
}
```

GOOD:

```json
{
  "decision_context_id": "eyJ...",
  "guest_message": "Cuál es la contraseña del WiFi?"
}
```

The AI can ask for information. Rails decides which property, guest, conversation, and reservation the tool is allowed to access.

## 11. Security Rules

Never trust:

- parameters sent by the AI;
- ids sent by the AI;
- authorizations claimed by the AI;
- source ids invented by the AI;
- confidence scores from the AI;
- statements that the AI says are true;
- proposed actions from the AI.

Rails must verify every authorization.

Sensitive information includes, at minimum:

- credentials, secrets, passwords, codes, or private links;
- key, lock, entrance, or building-access details;
- exact private host details;
- guest personal data;
- payment or billing information;
- private operational instructions;
- any information that could let the wrong person access the property.

BAD:

```json
{
  "decision": "reply",
  "message_body": "The private access credential is 1234.",
  "sensitive_info_used": false
}
```

GOOD:

```json
{
  "decision": "reply",
  "message_body": "Only return sensitive information when Rails has verified the guest is authorized.",
  "sensitive_info_used": true
}
```

Rails must still verify that the guest is authorized before sending.

## 12. Escalation Contract

The AI may return:

```json
{
  "decision": "escalate"
}
```

But the AI must not:

- create the alert;
- claim the alert exists;
- claim the host was notified;
- claim a human is already reviewing it;
- claim a WhatsApp was sent to the owner.

Rails creates alerts.

Rails decides whether a guest-facing message can say that the host was notified.

BAD:

```text
Ya le avisamos al anfitrión y te responderá pronto.
```

when Rails has not created the alert yet.

GOOD:

```text
No tengo esa información confirmada todavía. Voy a pedir que el anfitrión la revise.
```

Then Rails may create the alert and send an approved message.

## 13. Observability Is Mandatory

Everything important must be recorded.

The system must preserve:

- original incoming message;
- routing/init messages;
- system messages;
- AI candidate response;
- tools used;
- tool inputs, when safe;
- tool outputs, when safe;
- source ids / evidence ids;
- validator result;
- validator rejection reasons;
- blocked decisions;
- escalations;
- fallbacks;
- delivery attempts;
- delivery failures;
- provider message ids;
- provider statuses;
- operational errors.

For AI decisions, the system should preserve:

- tools considered;
- tools called;
- retry attempts;
- reformulated searches;
- evidence found;
- evidence rejected;
- clarifying questions considered;
- why escalation was necessary;
- why a fallback was used;
- why a decision was blocked.

Never sacrifice observability for simplicity.

BAD:

```text
If WhatsApp send fails, do not save anything.
```

GOOD:

```text
Save the attempted outbound message with delivery_status = failed.
Show it in the conversation timeline.
Record the provider error if available.
```

BAD:

```text
Drop rejected AI decisions silently.
```

GOOD:

```text
Persist why Rails rejected the decision and which validation rule failed.
```

## 14. Generic Capability Design

Do not encode the architecture around today's fields, intents, or tools.

Ayla should still work when the product has hundreds of additional capabilities and tools.

Therefore:

- prefer generic evidence contracts over per-field branches;
- prefer tool discovery and source ranking over hardcoded topic maps;
- prefer model interpretation plus Rails validation over local regex expansion;
- prefer reusable validation rules over one-off fixes;
- prefer evidence sufficiency checks over topic-specific patches;
- prefer narrow tool schemas that return evidence consistently;
- prefer adding better knowledge to tools over adding more router behavior.

BAD:

```text
If message contains one particular field name, force one particular answer path.
```

GOOD:

```text
If any relevant tool returns sufficient valid evidence for the user's request, the AI answers with that evidence and Rails validates it.
```

## 15. When In Doubt

When a guest message is not trivial:

Do not add logic to the router.

Do not add another regex.

Do not hardcode more phrasing.

Always prefer:

```text
AI + tools + evidence + clarification + Rails validation
```

If the AI cannot answer safely:

1. gather more information through tools;
2. retry or reformulate search;
3. ask a clarifying question;
4. escalate with Rails creating the alert only when the previous steps cannot reasonably resolve the issue.

## 16. Maximum Rule

If a modification causes any of the following:

- the AI participates less in real guest questions;
- the deterministic router participates more in real guest questions;
- less evidence is required;
- escalation happens earlier;
- clarification happens less often;
- evidence from tools is ignored;
- Rails loses authority;
- tools accept unsafe ids;
- sensitive information is easier to leak;
- responses can be invented;
- delivery attempts disappear from the timeline;
- errors become less observable;

then the modification is architecturally incorrect and must be rejected.

The desired architecture is:

```text
Guest message
→ Rails resolves signed context
→ Rails records the message
→ AI interprets the real question
→ AI gathers information progressively
→ AI calls all relevant tools
→ AI retries or reformulates when needed
→ AI cites sufficient evidence
→ AI asks a clarifying question when that can resolve uncertainty
→ Rails validates
→ Rails authorizes
→ Rails persists
→ Rails sends, blocks, or escalates as last resort
→ Rails records the outcome
```

The AI helps Ayla understand and write.

Rails keeps Ayla safe.
