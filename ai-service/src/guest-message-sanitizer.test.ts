import assert from "node:assert/strict";
import test from "node:test";
import { sanitizeDecisionGuestText, sanitizeGuestVisibleText } from "./guest-message-sanitizer.js";

test("sanitizeGuestVisibleText removes parenthesized source metadata", () => {
  assert.equal(
    sanitizeGuestVisibleText("Le check-in est à 15:00. (Source : property.check_in_time)"),
    "Le check-in est à 15:00.",
  );
});

test("sanitizeGuestVisibleText removes internal evidence and source references", () => {
  assert.equal(
    sanitizeGuestVisibleText("El check-in es a las 15:00. evidence_id: property.check_in_time"),
    "El check-in es a las 15:00.",
  );
  assert.equal(
    sanitizeGuestVisibleText("El check-in es a las 15:00. property_fact:check_in_time"),
    "El check-in es a las 15:00.",
  );
  assert.equal(
    sanitizeGuestVisibleText("El check-in es a las 15:00. [source]"),
    "El check-in es a las 15:00.",
  );
});

test("sanitizeGuestVisibleText removes tool names and technical field references", () => {
  assert.equal(
    sanitizeGuestVisibleText("Lo confirmé con stay_facts y property.check_in_time: el check-in es a las 15:00."),
    "Lo confirmé con y: el check-in es a las 15:00.",
  );
});

test("sanitizeGuestVisibleText preserves normal guest-facing text", () => {
  assert.equal(
    sanitizeGuestVisibleText("El check-in es a las 15:00. Si necesitás algo más, avisame."),
    "El check-in es a las 15:00. Si necesitás algo más, avisame.",
  );
});

test("sanitizeDecisionGuestText only sanitizes guest-facing text fields", () => {
  const decision = sanitizeDecisionGuestText({
    message_body: "El check-in es a las 15:00. (Source: property.check_in_time)",
    response_text: "El check-in es a las 15:00. source_id: property_fact:check_in_time",
    evidence_ids: ["property.check_in_time"],
    used_source_ids: ["property_fact:check_in_time"],
    audit: {
      evidence_catalog: [{ evidence_id: "property.check_in_time" }],
    },
  });

  assert.equal(decision.message_body, "El check-in es a las 15:00.");
  assert.equal(decision.response_text, "El check-in es a las 15:00.");
  assert.deepEqual(decision.evidence_ids, ["property.check_in_time"]);
  assert.deepEqual(decision.used_source_ids, ["property_fact:check_in_time"]);
  assert.deepEqual(decision.audit, {
    evidence_catalog: [{ evidence_id: "property.check_in_time" }],
  });
});
