# Security hardening baseline

This document records the September 2026 security-only review. It does not
change the Copilot product flow or make retired guest automation reachable.

## Supported runtime

- Ruby 3.4.10
- Rails 8.1.3.1, with the application's reviewed `7.1` framework defaults kept
  temporarily instead of accepting every new default blindly
- Node.js 20.6 or newer for the AI service
- PostgreSQL through the `pg` adapter

Production Rails boots require `RAILS_MASTER_KEY`. Docker asset compilation is
the only exception: it uses `SECRET_KEY_BASE_DUMMY` and never copies a master
key into an image layer. The running service must not set that build-only flag.

## Browser and authentication controls

- HTTPS is assumed at the trusted reverse proxy and forced by Rails.
- The cookie session is HTTP-only, `SameSite=Lax`, and secure in production.
- Login attempts are limited to 10 per three-minute window.
- Rails CSRF protection remains enabled.
- CSP defaults to same-origin content, forbids objects and framing, and uses a
  per-request nonce for scripts. Inline styles remain temporarily allowed for
  the current Tailwind/Rails view layer.

## URL and outbound-request review

`KnowledgeBlock#youtube_url` is parsed as a URI and accepts only HTTPS on the
explicit official hosts `youtube.com`, `www.youtube.com`, `m.youtube.com`, and
`youtu.be`, with no credentials or non-standard port. These URLs are stored and
rendered; the Rails backend does not fetch them, so private-network SSRF filters
are not applicable to that field.

The active Copilot HTTP destination and its signed tool callback origin come
from deployment configuration, not user input. Scoped tool requests reconstruct
account, property, user, and thread context in Rails. Stripe and Resend use fixed
HTTPS endpoints. DeepL uses an operator-configured endpoint and bounded open/read
timeouts. No redirect-following metadata fetcher was found in the active Copilot
path.

## Secrets

Only encrypted Rails credentials are tracked. Master keys and environment files
are ignored; `.env.example` contains names and empty placeholders only. Runtime
provider credentials stay in environment variables. No recognizable private
key or provider-token literal was found in tracked application files during this
review. If a credential has ever been committed outside the current repository
history, it still needs provider-side rotation.

## Copilot invariant

The active pipeline ends after persisting a suggestion. Its output schema is
strict and rejects extra action/effect fields. Node keeps only evidence IDs
returned by the current run's account/property-scoped tools. Rails architecture
tests reject references from runtime controllers or jobs to retired guest
automation, WhatsApp senders, OwnerTask/Alert creators, or Observer delivery.

## Deployment notes and residuals

- No repository CI or platform deployment manifest exists; runtime versions
  must also be selected in the deployment platform outside this repository.
- Production does not explicitly configure a durable Active Job adapter. The
  remaining enqueued legacy jobs are unreachable/no-op from current Copilot,
  but durable background work will require an explicit adapter before adding
  new job-dependent product behavior.
- Active Storage is configured locally, but no model attachment declarations
  are active. Property import processes the submitted upload synchronously.
- `npm audit` reports three low-severity findings in Vercel AI SDK 5 transitive
  packages. The published fix requires AI SDK 7 and Node 22, a breaking runtime
  migration. That migration is intentionally deferred rather than forced into
  this compatibility-focused round.
- Historical legacy tests emit Ruby warnings for `ostruct` becoming a bundled
  gem and duplicate JSON hash keys. The active Copilot path is unaffected, but
  those fixtures should be cleaned before a future Ruby 4 upgrade.
