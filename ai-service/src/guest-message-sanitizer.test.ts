import assert from "node:assert/strict";
import test from "node:test";
import { sanitizeDecisionGuestText, sanitizeGuestVisibleText } from "./guest-message-sanitizer.js";

test("sanitizeGuestVisibleText removes parenthesized source metadata", () => {
  assert.equal(
    sanitizeGuestVisibleText("Le check-in est à 15:00. (Source : property.check_in_time)"),
    "Le check-in est à 15:00.",
  );
  assert.equal(
    sanitizeGuestVisibleText("El check-in es a las 15:00. (Fuente:)"),
    "El check-in es a las 15:00.",
  );
  assert.equal(
    sanitizeGuestVisibleText("Заезд возможен с 15:00. (Источник: property.check_in_time)"),
    "Заезд возможен с 15:00.",
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

test("sanitizeGuestVisibleText preserves operational instructions, codes, sequences, and exact URLs", () => {
  const response = [
    "The entrance uses an electronic lock. Go to floor 1, apartment E at 15:00.",
    "Tap the panel, enter code 4826, and then press #.",
    "WiFi: Ayla Guest. Password: Clave-9X.",
    "Video: https://www.youtube.com/watch?v=IngresoABC123&t=42s#paso-2",
  ].join("\n");

  assert.equal(sanitizeGuestVisibleText(response), response);
});

test("sanitizeGuestVisibleText does not invent or rewrite a missing URL", () => {
  const response = "Subí al piso 1, puerta E. Ingresá 4826 y después presioná #.";

  assert.equal(sanitizeGuestVisibleText(response), response);
  assert.doesNotMatch(String(sanitizeGuestVisibleText(response)), /https?:\/\//);
});

test("sanitizeGuestVisibleText removes internal policy directives", () => {
  assert.equal(
    sanitizeGuestVisibleText("Late checkout: always_escalate."),
    null,
  );
  assert.equal(
    sanitizeGuestVisibleText("La solicitud requiere confirmación. policy: approval_required."),
    "La solicitud requiere confirmación.",
  );
});

test("sanitizeGuestVisibleText removes source claim phrases without removing the answer", () => {
  assert.equal(
    sanitizeGuestVisibleText("Según la información disponible, el check-in es a las 15:00."),
    "El check-in es a las 15:00.",
  );
  assert.equal(
    sanitizeGuestVisibleText("According to my records, check-in is at 15:00."),
    "Check-in is at 15:00.",
  );
  assert.equal(
    sanitizeGuestVisibleText("В базе данных указано, что заезд возможен с 15:00."),
    "Заезд возможен с 15:00.",
  );
});

test("sanitizeGuestVisibleText removes acknowledgement and clarification echo prefixes", () => {
  assert.equal(
    sanitizeGuestVisibleText("Perfecto: el check-in es a las 15:00. (Fuente:)"),
    "El check-in es a las 15:00.",
  );
  assert.equal(
    sanitizeGuestVisibleText("Perfecto, te referís al horario de ingreso. El check-in es a las 15:00."),
    "El check-in es a las 15:00.",
  );
  assert.equal(
    sanitizeGuestVisibleText("Correcto (check-in): el check-in es a las 15:00."),
    "El check-in es a las 15:00.",
  );
});

test("sanitizeDecisionGuestText only sanitizes guest-facing text fields", () => {
  const decision = sanitizeDecisionGuestText({
    message_body: "El check-in es a las 15:00. (Source: property.check_in_time)",
    response_text: "El check-in es a las 15:00. source_id: property_fact:check_in_time",
    safe_fallback_response: "Necesito revisar esa información. (Fuente: property.check_in_time)",
    evidence_ids: ["property.check_in_time"],
    used_source_ids: ["property_fact:check_in_time"],
    audit: {
      evidence_catalog: [{ evidence_id: "property.check_in_time" }],
    },
  });

  assert.equal(decision.message_body, "El check-in es a las 15:00.");
  assert.equal(decision.response_text, "El check-in es a las 15:00.");
  assert.equal(decision.safe_fallback_response, "Necesito revisar esa información.");
  assert.deepEqual(decision.evidence_ids, ["property.check_in_time"]);
  assert.deepEqual(decision.used_source_ids, ["property_fact:check_in_time"]);
  assert.deepEqual(decision.audit, {
    evidence_catalog: [{ evidence_id: "property.check_in_time" }],
  });
});
