# Ayla Manager

Ayla Manager is a Rails SaaS MVP for Airbnb and short-term rental owners. Owners configure property knowledge, local recommendations, FAQs, and AI instructions; guests ask questions through WhatsApp; the AI answers only from owner-provided information and creates alerts when owner action is needed.

## Stack

- Ruby on Rails 7.1
- PostgreSQL
- Tailwind CSS
- Stripe Checkout and Customer Portal skeleton for subscriptions
- Resend email service skeleton
- WhatsApp provider abstraction with a Twilio provider
- Optional Node/Vercel AI SDK service boundary

## Local Setup

```bash
bundle install
bin/rails db:prepare
bin/rails db:seed
bin/dev
```

If Foreman is not installed, `bin/dev` runs Rails only. Start Tailwind watching in a second terminal with:

```bash
bin/rails tailwindcss:watch
```

Seed login:

- Email: `owner@ayla.test`
- Password: `password123`

Admin seed login:

- Email: `admin@ayla.test`
- Password: `password123`

## Environment

Copy `.env.example` into your deployment environment and fill only the providers you want enabled. Credentials are read from environment variables and are not stored in the database.

AI safety flags default to conservative behavior:

- `AI_SERVICE_URL`: optional Node AI service URL. Rails uses deterministic routing and conservative fallback when this is blank or unavailable.
- `AI_SERVICE_TOKEN`: optional shared bearer token for Rails to call the Node AI service.
- `AI_GATEWAY_API_KEY`: required by the Node AI service for local Vercel AI Gateway calls. On Vercel, gateway auth can also be provided automatically by the platform.
- `AI_MODEL`: optional Vercel AI Gateway model id for the Node AI service. Defaults to `openai/gpt-5-mini`.
- `AI_SAFE_ROUTER_ENABLED`: defaults to enabled. Handles emergencies, exact safe facts, sensitive facts, and sensitive requests in Rails before AI.
- `AI_EVIDENCE_REQUIRED`: defaults to enabled. Rails rejects AI replies without validated same-property evidence.
- `AI_CONSERVATIVE_FALLBACK_ENABLED`: defaults to enabled. Rails avoids broad keyword fallback when the AI service is unavailable.
- `AI_TOOLS_ENABLED`: defaults to enabled in the Node AI service. Tools are read-only and scoped to the current Rails-provided conversation context.
- `AI_MIN_REPLY_CONFIDENCE`: optional minimum confidence for AI replies. Defaults to `0.55`.

## Core Loop

1. Owner creates a property.
2. Owner tags properties, adds guest guide blocks, FAQs, recommendations, and AI instructions.
3. WhatsApp webhook receives a guest message.
4. Ayla Manager finds or creates the guest and conversation.
5. `AI::DecisionService` builds a property-specific context and returns structured JSON.
6. Ayla Manager replies through the configured WhatsApp provider when safe.
7. Ayla Manager creates alerts for emergencies, unknown questions, late checkout, refunds, maintenance, missing items, and other owner-approval situations.

## Plans

| Plan | Internal ID | Monthly price | Property limit |
| --- | --- | ---: | ---: |
| Starter | `starter` | USD 15 | 3 |
| Growth | `growth` | USD 39 | 10 |
| Scale | `pro` | USD 79 | 25 |
| Pro | `business` | USD 149 | 50 |

## Reuse and QR

Property content can be reused in two ways:

- Start a new guide block, FAQ, or recommendation from an existing item on another property.
- Open a property and copy selected content from another property, including stay details, tags, guide blocks, recommendations, and FAQs.

Each property has a WhatsApp deep link and QR code under its detail page. The QR embeds a property reference so incoming WhatsApp messages can be routed back to the correct property when guests start from the code.
