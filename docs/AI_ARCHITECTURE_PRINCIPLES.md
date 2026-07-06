# Ayla AI Architecture Principles

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
- access;
- WiFi;
- keys;
- codes;
- check-in;
- checkout;
- policies;
- recommendations;
- prices;
- availability;
- house rules;
- amenities;
- appliances;
- local instructions.

The AI must obtain information through tools.

BAD:

```text
I think check-in is usually at 15:00.
```

GOOD:

```text
Call property_brain or the relevant stay/property tool.
Answer only using a returned source id / evidence id.
```

BAD:

```text
Most buildings allow visitors, so guests can probably invite someone.
```

GOOD:

```text
Call property_brain.
If no visitor policy is found, ask a clarifying question or escalate.
Do not invent a policy.
```

## 3. Evidence-First Is Mandatory

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

## 4. Rails Is The Authority

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

## 5. Deterministic Router Must Stay Minimal

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
- answer FAQs;
- answer check-in;
- answer checkout;
- answer WiFi;
- answer access instructions;
- answer parking;
- answer rules;
- answer recommendations;
- answer appliance questions;
- answer local guide questions;
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
The AI uses tools and evidence.
If ambiguous, the AI asks a clarifying question.
Rails validates the result.
```

## 6. Ambiguity Belongs To The AI

Ambiguity must be resolved by the AI, not by adding more router rules.

Example:

```text
a qué hora puedo ir
```

This could mean:

- check-in time;
- earliest arrival;
- luggage drop-off;
- building access time;
- appointment time;
- checkout/departure time in a confused phrasing.

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
El check-in es a las 15:00.
```

GOOD:

```text
¿Te referís al horario de check-in para llegar, o a otra cosa como dejar equipaje antes?
```

## 7. Signed Context Only

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

## 8. Security Rules

Never trust:

- parameters sent by the AI;
- ids sent by the AI;
- authorizations claimed by the AI;
- source ids invented by the AI;
- confidence scores from the AI;
- statements that the AI says are true;
- proposed actions from the AI.

Rails must verify every authorization.

Sensitive access includes, at minimum:

- WiFi password;
- lockbox code;
- door code;
- key location;
- access instructions;
- exact access timing if restricted;
- private host details;
- any information that could let the wrong person access the property.

BAD:

```json
{
  "decision": "reply",
  "message_body": "The lockbox code is 1234.",
  "sensitive_info_used": false
}
```

GOOD:

```json
{
  "decision": "reply",
  "message_body": "El código de acceso es 1234.",
  "sensitive_info_used": true,
  "used_source_ids": ["sensitive_access_instructions"]
}
```

Rails must still verify that the guest is authorized before sending.

## 9. Escalations

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

## 10. Observability Is Mandatory

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

## 11. When In Doubt

When a guest message is not trivial:

Do not add logic to the router.

Do not add another regex.

Do not hardcode more phrasing.

Always prefer:

```text
AI + tools + evidence + Rails validation
```

If the AI cannot answer safely:

1. ask a clarifying question, or
2. escalate with Rails creating the alert.

## 12. Maximum Rule

If a modification causes any of the following:

- the AI participates less in real guest questions;
- the deterministic router participates more in real guest questions;
- less evidence is required;
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
→ AI calls tools
→ AI cites evidence
→ Rails validates
→ Rails authorizes
→ Rails persists
→ Rails sends or escalates
→ Rails records the outcome
```

The AI helps Ayla understand and write.

Rails keeps Ayla safe.
