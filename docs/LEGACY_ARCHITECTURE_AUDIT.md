# Final legacy architecture audit

This is the post-Copilot classification. “Runtime” means reachable from a controller, callback or job in the current application.

| Component | Classification | Current treatment |
| --- | --- | --- |
| Copilot threads/messages/runs, signed tools, AI Trace | KEEP | Primary runtime. |
| Property knowledge, FAQs, recommendations, stays, sensitive data | KEEP | Property-scoped Copilot retrieval. |
| `Conversation`, `Message`, `Guest` | KEEP | Historical/read-only audit data. |
| `OwnerTask`, `Alert`, `CheckoutEvent` | KEEP | Historical records; no Copilot effect path. |
| Historical message translation | KEEP | Presentation only; it cannot send. |
| Twilio signature validation and status callback | KEEP | Authenticity and late historical delivery audit. |
| Meta WhatsApp integration | KEEP (none) | No Meta runtime integration exists in this repository. |
| `Whatsapp::IncomingMessageHandler` | DEPRECATE | Legacy source retained for forensic comparison; unreachable from controllers/jobs. |
| `AI::DecisionService` and old Node decision modules | DEPRECATE | No Rails runtime caller; `/decide` returns 410. |
| `OwnerTasks::Creator`, `Alerts::Creator`, `CheckoutEvents::Creator` | DEPRECATE | Legacy builders unreachable from runtime entrypoints. |
| `OwnerInboundMessageHandler`, `OwnerAssistant`, owner sessions | DEPRECATE | Historical state retained; webhook no longer routes to it. |
| `OwnerReplySender`, `HostReplyDelivery` | DEPRECATE | Legacy source only; web endpoints return 410. |
| Observer recorder/notifier/activity model | DEPRECATE | Data retained; callbacks removed and queued jobs are no-ops. |
| Legacy notification/retry jobs | DEPRECATE | Previously serialized jobs deserialize safely; Observer and owner-alert jobs are inert. |
| Guest/reservation identification services | DEPRECATE | Retained for historical inspection; no inbound runtime calls them. |
| Twilio delivery callback | KEEP | It can only update delivery metadata on an existing historical message; it cannot send. |
| Guest property token / deep-link / QR services | DEPRECATE | Tokens remain; QR UI removed and route returns 410. |
| Legacy operation dashboards | REFACTOR | Records remain visible under “Operación anterior” and are read-only where they could trigger delivery. |
| Guest automation test corpus | REFACTOR | Archive as former specification; current runtime tests assert retirement and safety. |
| Reply UI, observer settings UI, automatic-AI toggle UI | DELETE | Removed from rendered product. |
| Guest WhatsApp routing and Node `/decide` execution | DELETE | Replaced by inert classification and HTTP 410. |

## Dead code found

The deprecated service groups are no longer reachable from controllers/jobs. They remain temporarily because they document historical records and a large legacy test corpus. Delete them in a later deletion-only change after confirming no production queue contains serialized legacy jobs and exporting any required forensic fixtures.

Concrete dead groups:

- `app/services/whatsapp/incoming_message_handler.rb` and the owner WhatsApp router/state machine.
- `app/services/whatsapp/owner_reply_sender.rb`, `host_reply_delivery.rb`, escalation and Observer notifiers.
- `app/services/ai/decision_service.rb`, its validator/effect creators, and the Node legacy decision implementation behind retired `/decide`.
- Observer activity recording and navigation services. The table/model remains historical only.
- Guest deep-link/QR generation and automatic guest channel bootstrap.
- Legacy template registry entries and Twilio provider code. They have no active sending caller.

## Safety checks

- `CopilotRuntimeBoundaryTest` rejects legacy automation constants in controllers/jobs.
- `CopilotDraftServiceTest` proves a successful suggestion does not construct a WhatsApp provider or create legacy effects.
- Webhook integration tests prove guest tokens and host phone numbers cannot enter former WhatsApp workflows.
