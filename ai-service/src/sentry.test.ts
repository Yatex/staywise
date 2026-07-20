import assert from "node:assert/strict";
import test from "node:test";
import {
  sanitizeSentryValue,
  sentryEnabled,
  shouldIgnoreSentryPath,
} from "./sentry.js";

test("Sentry remains disabled without a DSN", () => {
  assert.equal(sentryEnabled(), false);
});

test("Sentry sanitization removes sensitive AI and guest data", () => {
  assert.deepEqual(sanitizeSentryValue({
    conversation_id: 12,
    guest_message: "código 1234",
    prompt: "full prompt",
    tool_response: { evidence: "secret" },
    access_code: "1234",
    error_detail: "request failed authorization=Bearer-secret",
  }), {
    conversation_id: 12,
    guest_message: "[FILTERED]",
    prompt: "[FILTERED]",
    tool_response: "[FILTERED]",
    access_code: "[FILTERED]",
    error_detail: "request failed authorization=[FILTERED]",
  });
});

test("scanner paths are ignored", () => {
  assert.equal(shouldIgnoreSentryPath("/wp-admin"), true);
  assert.equal(shouldIgnoreSentryPath("/sitemap.xml"), true);
  assert.equal(shouldIgnoreSentryPath("/decide"), false);
});
