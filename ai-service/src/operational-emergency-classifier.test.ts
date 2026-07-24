import assert from "node:assert/strict";
import test from "node:test";
import { applyOperationalEmergencyGuardrail, operationalRiskFor } from "./operational-emergency-classifier.js";

const cases = [
  ["Se está incendiando la cocina", true],
  ["Hay humo saliendo del horno", true],
  ["Se está inundando el departamento", true],
  ["Entró un ladrón", true],
  ["Hay un cortocircuito en el dormitorio", true],
  ["Necesito una cuna urgente", false],
  ["Necesito leche urgente", false],
  ["Necesito más toallas urgente", false],
  ["Necesito una cama adicional", false],
] as const;

for (const [message, emergency] of cases) {
  test(`${message} → ${emergency ? "alert" : "request"}`, () => {
    const modelDecision = {
      action: "create_owner_task",
      owner_task_kind: "request",
      owner_task_id: null,
      title: emergency ? "Riesgo reportado por huésped" : "Atender pedido del huésped",
      task_summary: message,
      message: "Recibí tu mensaje y estoy avisando al anfitrión.",
    };
    const decision = applyOperationalEmergencyGuardrail(modelDecision, message);

    assert.equal(decision.action, emergency ? "create_alert" : "create_owner_task");
    assert.equal(decision.owner_task_kind, emergency ? null : "request");
    assert.equal(Boolean(operationalRiskFor(message)), emergency);
    if (emergency) {
      assert.equal(decision.title, modelDecision.title, "the AI-generated title must be preserved");
      assert.equal(decision.escalation.category, "emergency");
    }
  });
}

test("urgency words alone never create operational risk", () => {
  assert.equal(operationalRiskFor("Lo necesito urgente, rápido y cuanto antes"), null);
});
