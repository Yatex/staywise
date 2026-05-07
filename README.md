# Staywise

Staywise is a Rails SaaS MVP for Airbnb and short-term rental owners. Owners configure property knowledge, local recommendations, FAQs, and AI instructions; guests ask questions through WhatsApp; the AI answers only from owner-provided information and creates alerts when owner action is needed.

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

- Email: `owner@staywise.test`
- Password: `password123`

Admin seed login:

- Email: `admin@staywise.test`
- Password: `password123`

## Environment

Copy `.env.example` into your deployment environment and fill only the providers you want enabled. Credentials are read from environment variables and are not stored in the database.

## Core Loop

1. Owner creates a property.
2. Owner tags properties, adds guest guide blocks, FAQs, recommendations, and AI instructions.
3. WhatsApp webhook receives a guest message.
4. Staywise finds or creates the guest and conversation.
5. `AI::DecisionService` builds a property-specific context and returns structured JSON.
6. Staywise replies through the configured WhatsApp provider when safe.
7. Staywise creates alerts for emergencies, unknown questions, late checkout, refunds, maintenance, missing items, and other owner-approval situations.

## Reuse and QR

Property content can be reused in two ways:

- Start a new guide block, FAQ, or recommendation from an existing item on another property.
- Open a property and copy selected content from another property, including stay details, tags, guide blocks, recommendations, and FAQs.

Each property has a WhatsApp deep link and QR code under its detail page. The QR embeds a property reference so incoming WhatsApp messages can be routed back to the correct property when guests start from the code.
