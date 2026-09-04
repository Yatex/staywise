# Ayla Manager

Ayla Manager is a Rails SaaS Copilot for short-term-rental hosts. An authenticated host selects a property, pastes a message received from a guest, and gets a grounded draft to review and copy. Ayla never sends that draft to the guest and never creates an operational effect automatically.

## Current product flow

```text
authenticated host
  -> selects an account-scoped property
  -> pastes a guest message and optional context
  -> Rails creates a CopilotThread / CopilotMessage / CopilotRun
  -> ayla-manager-ai retrieves required property knowledge through signed tools
  -> Rails validates and stores the structured suggestion
  -> host reviews and copies guest_reply
```

Rails owns authentication, tenancy, authorization and persistence. The Node AI service owns semantic reasoning and retrieval. There is deliberately no edge from the Copilot pipeline to a WhatsApp provider, `Message`, `OwnerTask`, `Alert`, or `CheckoutEvent`.

Guest conversations, messages, AI traces, OwnerTasks, alerts and checkout events from the previous product are retained as audit records. Their screens are grouped under **Operación anterior** and guest conversations are read-only. Guest QR links, automatic guest replies, Observer Mode and the owner operational WhatsApp state machine are retired from runtime.

See [Copilot architecture](docs/COPILOT_ARCHITECTURE.md) and the [final legacy audit](docs/LEGACY_ARCHITECTURE_AUDIT.md).

## Stack

- Ruby 3.4.10 / Rails 8.1.3.1 / PostgreSQL / Tailwind CSS
- Node 20+ / TypeScript / Vercel AI SDK
- Stripe billing skeleton
- Sentry-compatible operational error reporting

## Local setup

```bash
bundle install
bin/rails db:prepare
bin/rails db:seed
bin/dev
```

Run the AI service separately:

```bash
cd ai-service
npm install
npm run dev
```

Core environment variables:

- `AI_SERVICE_URL`: URL of the Node service.
- `AI_SERVICE_TOKEN`: bearer token for Rails-to-Node and signed tool access.
- `AI_GATEWAY_API_KEY`: model gateway credential used only by Node.
- `AI_MODEL`: optional model id.
- `AI_TOOLS_BASE_URL` or `APP_HOST`: Rails origin used for scoped Copilot tools.

Legacy WhatsApp credentials may remain while historical delivery callbacks settle, but they are not part of the Copilot pipeline.

Production boots require `RAILS_MASTER_KEY`, terminate TLS at a trusted proxy,
force HTTPS, use secure HTTP-only same-site cookies, and enforce a Content
Security Policy. See [Security hardening](docs/SECURITY_HARDENING.md) for the
reviewed runtime boundary and deployment requirements.

## Verification

```bash
bin/rails test
bin/rails test:system
cd ai-service && npm test && npm run typecheck
bundle exec rubocop
bundle exec brakeman --no-pager
```
