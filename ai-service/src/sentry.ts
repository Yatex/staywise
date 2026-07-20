import * as Sentry from "@sentry/node";
import { nodeProfilingIntegration } from "@sentry/profiling-node";

const FILTERED = "[FILTERED]";
const sensitiveKey = /authorization|token|secret|password|passw|wifi|code|key|lockbox|decision_context|prompt|message|body|content|evidence|reservation|phone|guest_name|tool_response/i;
const scannerPath = /\/(?:wp-admin|wp-login|wordpress|phpmyadmin|\.env|sitemap\.xml)(?:\/|$)/i;

if (process.env.SENTRY_DSN) {
  Sentry.init({
    dsn: process.env.SENTRY_DSN,
    environment: process.env.SENTRY_ENVIRONMENT || process.env.NODE_ENV,
    release: process.env.SENTRY_RELEASE,
    tracesSampleRate: numberFromEnvironment("SENTRY_TRACES_SAMPLE_RATE"),
    profilesSampleRate: numberFromEnvironment("SENTRY_PROFILES_SAMPLE_RATE"),
    sendDefaultPii: false,
    integrations: [
      nodeProfilingIntegration(),
      Sentry.vercelAIIntegration({ recordInputs: false, recordOutputs: false }),
    ],
    beforeSend(event) {
      const requestPath = pathFromUrl(event.request?.url);
      if (requestPath && shouldIgnoreSentryPath(requestPath)) return null;

      event.user = undefined;
      event.request = event.request ? {
        method: event.request.method,
        url: event.request.url?.split("?")[0],
        headers: pickSafeHeaders(event.request.headers),
      } : undefined;
      event.extra = sanitizeSentryValue(event.extra) as Record<string, unknown>;
      event.contexts = sanitizeSentryValue(event.contexts) as Record<string, any>;
      return event;
    },
    beforeBreadcrumb(breadcrumb) {
      if (breadcrumb.category?.startsWith("console")) return null;
      breadcrumb.data = sanitizeSentryValue(breadcrumb.data) as Record<string, unknown>;
      breadcrumb.message = sanitizeSentryText(breadcrumb.message);
      return breadcrumb;
    },
  });
}

export function sentryEnabled() {
  return Boolean(process.env.SENTRY_DSN);
}

export function withSentryRequestContext<T>(
  correlationId: string,
  tags: Record<string, string | number | null | undefined>,
  callback: () => Promise<T>,
) {
  if (!sentryEnabled()) return callback();

  return Sentry.withIsolationScope(async (scope) => {
    scope.setTags(compactTags({ ...tags, correlation_id: correlationId }));
    return callback();
  });
}

export function captureSafeException(
  error: unknown,
  tags: Record<string, string | number | null | undefined> = {},
) {
  if (!sentryEnabled()) return;

  Sentry.withScope((scope) => {
    scope.setTags(compactTags(tags));
    Sentry.captureException(error);
  });
}

export function sanitizeSentryValue(value: unknown, depth = 0): unknown {
  if (depth > 6) return "[TRUNCATED]";
  if (Array.isArray(value)) return value.slice(0, 50).map((item) => sanitizeSentryValue(item, depth + 1));
  if (value && typeof value === "object") {
    return Object.entries(value as Record<string, unknown>).reduce<Record<string, unknown>>((result, [key, item]) => {
      result[key] = sensitiveKey.test(key) ? FILTERED : sanitizeSentryValue(item, depth + 1);
      return result;
    }, {});
  }
  if (typeof value === "string") return sanitizeSentryText(value);
  return value;
}

function sanitizeSentryText(value?: string) {
  if (!value) return value;
  return value
    .replace(/(authorization|token|secret|password|passw|wifi|code|lockbox|phone)\s*[:=]\s*[^\s,;]+/gi, `$1=${FILTERED}`)
    .slice(0, 500);
}

export function shouldIgnoreSentryPath(path: string) {
  return scannerPath.test(path);
}

function numberFromEnvironment(name: string) {
  const parsed = Number(process.env[name] || "0");
  return Number.isFinite(parsed) && parsed >= 0 && parsed <= 1 ? parsed : 0;
}

function pathFromUrl(value?: string) {
  if (!value) return null;
  try {
    return new URL(value, "http://localhost").pathname;
  } catch {
    return null;
  }
}

function pickSafeHeaders(headers?: Record<string, string>) {
  if (!headers) return undefined;
  return Object.entries(headers).reduce<Record<string, string>>((result, [key, value]) => {
    if (["x-request-id", "content-type"].includes(key.toLowerCase())) result[key] = value;
    return result;
  }, {});
}

function compactTags(tags: Record<string, string | number | null | undefined>) {
  return Object.entries(tags).reduce<Record<string, string | number>>((result, [key, value]) => {
    if (value !== null && value !== undefined && value !== "") result[key] = value;
    return result;
  }, {});
}
