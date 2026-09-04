# Ayla Copilot architecture

## Authority boundary

Rails is authoritative for users, accounts, properties, permissions, tenant isolation, persistence and tool authorization. The AI service performs language detection, semantic reasoning and selective retrieval. Its output is a suggestion, never a command.

## Runtime flow

```text
User session
  -> CopilotThreadsController / CopilotMessagesController
  -> Copilot::DraftService
  -> Copilot::AIClient POST /copilot
  -> Node runCopilot
  -> signed /internal/ai/copilot_tools calls scoped to account/property/user/thread
  -> validated Copilot::ResponseContract
  -> CopilotRun + assistant CopilotMessage + AIDecisionLog
  -> browser renders a copyable draft
```

`CopilotThread`, `CopilotMessage` and `CopilotRun` all carry `account_id`, `property_id` and `user_id`. Model consistency validation and controller scopes prevent cross-account or cross-property reuse. Sensitive access information is available only through its dedicated signed tool.

## Outbound safety invariant

The Copilot pipeline has no provider parameter and no dependency on the `Whatsapp` namespace. It persists only Copilot records and audit traces. It does not create legacy `Message`, `OwnerTask`, `Alert`, or `CheckoutEvent` rows. The UI offers **Copiar respuesta**, not **Enviar**.

Public WhatsApp inbound is handled by `Whatsapp::CopilotInboundRouter`. It acknowledges and classifies events but intentionally has no provider, AI client or persistence dependency. Guest events return `guest_whatsapp_channel_retired`; known host numbers return `host_whatsapp_copilot_not_enabled`. Neither produces an outbound message.

The old Node `/decide` endpoint returns HTTP 410. The authenticated `/copilot` endpoint is the only endpoint for response drafting.

## Historical data

`Conversation`, `Message`, `Guest`, `OwnerTask`, `Alert`, `CheckoutEvent`, `OwnerReplyDraft`, `ConversationObserverActivity` and old `AIDecisionLog` records remain intact for auditing. Historical conversations can be viewed and translated, but response endpoints return HTTP 410.

## WhatsApp channels

- Guest ↔ host: outside Ayla, through the booking platform or host's own channel.
- Host ↔ Ayla: currently supported through authenticated web Copilot. The former central WhatsApp workflow is retired because it cannot safely select among properties without authenticated context.
- Twilio status callback: retained temporarily so late callbacks for historical messages can update delivery audit metadata.

## Tools

Copilot uses `/internal/ai/copilot_tools`. Each request carries a short-lived context tied to its thread and message. Tools enforce tenant scope server-side; Node cannot choose an arbitrary account or property.
