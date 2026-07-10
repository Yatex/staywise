import assert from "node:assert/strict";
import test from "node:test";
import { buildEvidenceCatalog } from "./evidence-catalog.js";
import { buildGroundedDecision } from "./grounded-decision-builder.js";

test("spanish greeting is answered as small talk without matching property evidence", () => {
  const result = buildGroundedDecision(unknownEscalation("es"), {
    guest_message: "hola buenas tardes",
  }, catalogFromSources([
    propertyFact("address", "property.address", "Av. Siempre Viva 123"),
    propertyFact("check_in_time", "property.check_in_time", "15:00"),
    propertyFact("parking_instructions", "property.parking_instructions", "Cochera 12"),
  ]));

  assert.equal(result.decision.outcome, "reply");
  assert.equal(result.decision.escalation_required, false);
  assert.equal(result.decision.detected_intents[0].type, "greeting");
  assert.deepEqual(result.decision.evidence_ids, []);
  assert.deepEqual(result.decision.safety_flags, []);
  assert.match(result.decision.message_body, /buenas tardes/i);
  assert.doesNotMatch(result.decision.message_body, /address|check_in|parking|Av\.|15:00|Cochera/i);
  assert.equal(result.decision.audit.grounded_decision_builder.grounded_decision_result.override_type, "conversational_only");
});

test("english greeting is answered as small talk without evidence", () => {
  const result = buildGroundedDecision(unknownEscalation("en"), {
    guest_message: "hello good afternoon",
  }, catalogFromSources([
    propertyFact("address", "property.address", "123 Test Street"),
    propertyFact("parking_instructions", "property.parking_instructions", "Garage spot 4"),
  ]));

  assert.equal(result.decision.outcome, "reply");
  assert.equal(result.decision.detected_intents[0].type, "greeting");
  assert.deepEqual(result.decision.evidence_ids, []);
  assert.match(result.decision.message_body, /Good afternoon/i);
  assert.doesNotMatch(result.decision.message_body, /address|parking|123 Test|Garage/i);
});

test("portuguese greeting is answered as small talk without evidence", () => {
  const result = buildGroundedDecision(unknownEscalation("pt"), {
    guest_message: "olá boa tarde",
  }, catalogFromSources([
    propertyFact("address", "property.address", "Rua Teste 123"),
    propertyFact("check_in_time", "property.check_in_time", "15:00"),
  ]));

  assert.equal(result.decision.outcome, "reply");
  assert.equal(result.decision.detected_intents[0].type, "greeting");
  assert.deepEqual(result.decision.evidence_ids, []);
  assert.match(result.decision.message_body, /Boa tarde/i);
  assert.doesNotMatch(result.decision.message_body, /address|check_in|Rua Teste|15:00/i);
});

test("thanks are answered as small talk without evidence", () => {
  const result = buildGroundedDecision(unknownEscalation("es"), {
    guest_message: "ok gracias",
  }, catalogFromSource(propertyFact("address", "property.address", "Av. Siempre Viva 123")));

  assert.equal(result.decision.outcome, "reply");
  assert.equal(result.decision.detected_intents[0].type, "small_talk");
  assert.deepEqual(result.decision.evidence_ids, []);
  assert.match(result.decision.message_body, /De nada|Perfecto/i);
  assert.doesNotMatch(result.decision.message_body, /address|Av\./i);
});

test("structured fact evidence answers check-in without unknown escalation", () => {
  const result = buildGroundedDecision(unknownEscalation("es"), {
    guest_message: "a que hora es el check in?",
  }, catalogFromSource({
    source_type: "property_fact",
    source_id: "property_fact:check_in_time",
    evidence_id: "property.check_in_time",
    field: "check_in_time",
    label: "check_in_time",
    value: "15:00",
  }));

  assert.equal(result.override?.reason, "sufficient_evidence");
  assert.equal(result.decision.outcome, "reply");
  assert.equal(result.decision.escalation_required, false);
  assert.notEqual(result.decision.detected_intents[0].type, "unknown");
  assert.deepEqual(result.decision.evidence_ids, ["property.check_in_time"]);
  assert.match(result.decision.message_body, /15:00/);
  assert.equal(result.decision.audit.grounded_decision_builder.should_repair_decision.value, true);
  assert.equal(result.decision.audit.grounded_decision_builder.evidence_catalog_size, 1);
  assert.equal(result.decision.audit.grounded_decision_builder.ranked_candidates[0].evidence_id, "property.check_in_time");
  assert.equal(result.decision.audit.grounded_decision_builder.grounded_decision_result.override_created, true);
  assert.equal(result.decision.audit.grounded_decision_builder.final_decision_source.grounded_override, true);
});

test("structured fact evidence answers checkout", () => {
  const result = buildGroundedDecision(unknownEscalation("es"), {
    guest_message: "y el checkout?",
  }, catalogFromSource({
    source_type: "property_fact",
    source_id: "property_fact:check_out_time",
    evidence_id: "property.check_out_time",
    field: "check_out_time",
    label: "check_out_time",
    value: "11:00",
  }));

  assert.equal(result.decision.outcome, "reply");
  assert.equal(result.decision.escalation_required, false);
  assert.deepEqual(result.decision.evidence_ids, ["property.check_out_time"]);
  assert.match(result.decision.message_body, /11:00/);
});

test("owner approval policy preserves the AI guest request action and never exposes control values", () => {
  const modelDecision = {
    outcome: "propose_action",
    decision: "propose_action",
    language: "es",
    message_body: "Recibí tu pedido. El anfitrión debe confirmarlo y te avisaremos cuando responda.",
    detected_intents: [
      { type: "guest_request", status: "requires_host_approval" },
      { type: "request_late_checkout", status: "requires_host_approval" },
    ],
    evidence_ids: ["policy.late_checkout"],
    required_capabilities: ["owner_attention"],
    proposed_action: { type: "request_late_checkout", payload: { requested_by_guest: true } },
    escalation_required: true,
    escalation: {
      required: true,
      reason_code: "guest_request",
      summary_for_host: "El huésped pidió una excepción que requiere aprobación.",
    },
    confidence: 0.92,
    safety_flags: [],
  };
  const result = buildGroundedDecision(modelDecision, {
    guest_message: "Quiero hacer un late checkout",
  }, catalogFromSource({
    source_type: "policy",
    source_id: "policy:late_checkout",
    evidence_id: "policy.late_checkout",
    field: "late_checkout",
    label: "late_checkout",
    value: "Requires owner approval.",
    policy_behavior: "requires_owner_approval",
    requires_owner_approval: true,
    control_only: true,
  }));

  assert.equal(result.decision.outcome, "propose_action");
  assert.equal(result.decision.escalation_required, true);
  assert.equal(result.decision.proposed_action.type, "request_late_checkout");
  assert.ok(result.decision.detected_intents.some((intent: any) => intent.type === "guest_request"));
  assert.ok(result.decision.detected_intents.some((intent: any) => intent.type === "request_late_checkout"));
  assert.doesNotMatch(result.decision.message_body, /always_escalate|approval_required/i);
});

test("arrival wording replies with inference from check-in evidence", () => {
  const result = buildGroundedDecision(unknownEscalation("es"), {
    guest_message: "a que hora puedo entrar al depto?",
  }, catalogFromSource({
    source_type: "property_fact",
    source_id: "property_fact:check_in_time",
    evidence_id: "property.check_in_time",
    field: "check_in_time",
    label: "check_in_time",
    value: "15:00",
  }));

  assert.equal(result.decision.outcome, "reply");
  assert.equal(result.decision.escalation_required, false);
  assert.deepEqual(result.decision.evidence_ids, ["property.check_in_time"]);
  assert.equal(result.decision.detected_intents[0].type, "check_in_time");
  assert.equal(result.decision.detected_intents[0].status, "answered_with_inference");
  assert.equal(result.decision.message_body, "El check-in es a las 15:00.");
  assert.equal(result.decision.audit.grounded_decision_builder.final_decision_strategy, "reply_with_inference");
});

test("generic go time with check-in and checkout asks clarification before escalating", () => {
  const result = buildGroundedDecision(unknownEscalation("es"), {
    guest_message: "a que hora puedo ir?",
  }, catalogFromSources([
    {
      source_type: "property_fact",
      source_id: "property_fact:check_in_time",
      evidence_id: "property.check_in_time",
      field: "check_in_time",
      label: "check_in_time",
      value: "15:00",
    },
    {
      source_type: "property_fact",
      source_id: "property_fact:check_out_time",
      evidence_id: "property.check_out_time",
      field: "check_out_time",
      label: "check_out_time",
      value: "11:00",
    },
  ]));

  assert.equal(result.decision.outcome, "ask_clarifying_question");
  assert.equal(result.decision.escalation_required, false);
  assert.equal(result.decision.detected_intents[0].type, "ambiguous_time");
  assert.deepEqual(result.decision.evidence_ids.sort(), ["property.check_in_time", "property.check_out_time"].sort());
  assert.match(result.decision.message_body, /entrada\/check-in/);
  assert.match(result.decision.message_body, /salida\/check-out/);
  assert.equal(result.decision.audit.grounded_decision_builder.final_decision_strategy, "clarify_before_escalate");
});

test("clarification follow-up answers using the same evidence", () => {
  const result = buildGroundedDecision(unknownEscalation("es"), {
    guest_message: "al check in",
    conversation_history: [
      { sender: "ai", body: "¿Te referís al horario de entrada/check-in o al horario de salida/check-out?" },
    ],
  }, catalogFromSources([
    {
      source_type: "property_fact",
      source_id: "property_fact:check_in_time",
      evidence_id: "property.check_in_time",
      field: "check_in_time",
      label: "check_in_time",
      value: "15:00",
    },
    {
      source_type: "property_fact",
      source_id: "property_fact:check_out_time",
      evidence_id: "property.check_out_time",
      field: "check_out_time",
      label: "check_out_time",
      value: "11:00",
    },
  ]));

  assert.equal(result.decision.outcome, "reply");
  assert.equal(result.decision.escalation_required, false);
  assert.deepEqual(result.decision.evidence_ids, ["property.check_in_time"]);
  assert.equal(result.decision.message_body, "El check-in es a las 15:00.");
  assert.doesNotMatch(result.decision.message_body, /refer/i);
  assert.doesNotMatch(result.decision.message_body, /perfecto|correcto/i);
});

test("arrival phrasing replies with inference", () => {
  const result = buildGroundedDecision(unknownEscalation("es"), {
    guest_message: "cuando puedo llegar?",
  }, catalogFromSource({
    source_type: "property_fact",
    source_id: "property_fact:check_in_time",
    evidence_id: "property.check_in_time",
    field: "check_in_time",
    label: "check_in_time",
    value: "15:00",
  }));

  assert.equal(result.decision.outcome, "reply");
  assert.equal(result.decision.detected_intents[0].status, "answered_with_inference");
  assert.match(result.decision.message_body, /15:00/);
});

test("departure phrasing replies with inference from checkout evidence", () => {
  const result = buildGroundedDecision(unknownEscalation("es"), {
    guest_message: "a qué hora puedo salir?",
  }, catalogFromSource({
    source_type: "property_fact",
    source_id: "property_fact:check_out_time",
    evidence_id: "property.check_out_time",
    field: "check_out_time",
    label: "check_out_time",
    value: "11:00",
  }));

  assert.equal(result.decision.outcome, "reply");
  assert.equal(result.decision.escalation_required, false);
  assert.deepEqual(result.decision.evidence_ids, ["property.check_out_time"]);
  assert.equal(result.decision.detected_intents[0].type, "check_out_time");
  assert.equal(result.decision.detected_intents[0].status, "answered_with_inference");
  assert.equal(result.decision.message_body, "El checkout es a las 11:00.");
});

test("vague issue asks a clarification before escalating", () => {
  const result = buildGroundedDecision(unknownEscalation("es"), {
    guest_message: "no anda",
  }, []);

  assert.equal(result.decision.outcome, "ask_clarifying_question");
  assert.equal(result.decision.escalation_required, false);
  assert.equal(result.decision.detected_intents[0].type, "ambiguous_issue");
  assert.match(result.decision.message_body, /WiFi, puerta, agua, luz/);
  assert.equal(result.decision.audit.grounded_decision_builder.final_decision_strategy, "clarify_before_escalate");
  assert.equal(result.decision.audit.grounded_decision_builder.decision_scores.safety_score, 50);
});

test("medium confidence asks clarification instead of escalating", () => {
  const result = buildGroundedDecision(unknownEscalation("en"), {
    guest_message: "What are the building hours?",
  }, buildEvidenceCatalog([{
    toolName: "property_brain",
    result: [
      source({
        source_type: "knowledge_block",
        source_id: "knowledge_block:1",
        evidence_id: "guide.1",
        label: "Pool hours",
        value: "The pool is open from 9 to 18.",
        category: "building",
      }),
      source({
        source_type: "knowledge_block",
        source_id: "knowledge_block:2",
        evidence_id: "guide.2",
        label: "Gym hours",
        value: "The gym is open from 8 to 20.",
        category: "building",
      }),
    ],
  }]));

  const scores = result.decision.audit.grounded_decision_builder.decision_scores;

  assert.equal(result.decision.outcome, "ask_clarifying_question");
  assert.equal(result.decision.escalation_required, false);
  assert.ok(scores.answer_confidence >= 40);
  assert.ok(scores.evidence_relevance_score >= 40);
});

test("medium relevance with one useful evidence group replies instead of asking extra questions", () => {
  const result = buildGroundedDecision(unknownEscalation("es"), {
    guest_message: "basura",
  }, catalogFromSource({
    source_type: "property_fact",
    source_id: "property_fact:trash_instructions",
    evidence_id: "property.trash_instructions",
    field: "trash_instructions",
    label: "Basura",
    value: "Sacá la basura al contenedor del subsuelo antes de las 20:00.",
  }));

  assert.equal(result.decision.outcome, "reply");
  assert.equal(result.decision.escalation_required, false);
  assert.deepEqual(result.decision.evidence_ids, ["property.trash_instructions"]);
  assert.match(result.decision.message_body, /contenedor del subsuelo/);
  assert.doesNotMatch(result.decision.message_body, /\?/);
  assert.equal(result.decision.audit.grounded_decision_builder.grounded_decision_result.override_type, "sufficient_evidence");
});

test("two clarification attempts without resolution leave escalation as last resort", () => {
  const result = buildGroundedDecision(unknownEscalation("es"), {
    guest_message: "no anda",
    conversation_history: [
      { sender: "ai", body: "¿Qué es lo que no está funcionando: WiFi, puerta, agua, luz u otra cosa?" },
      { sender: "ai", body: "¿Podés aclararme qué sigue sin funcionar exactamente?" },
    ],
  }, []);

  const trace = result.decision.audit.grounded_decision_builder;

  assert.equal(result.decision.outcome, "escalate");
  assert.equal(result.override, null);
  assert.equal(trace.clarification_attempts.count, 2);
  assert.equal(trace.grounded_decision_result.reason_if_null, "clarification_attempts_exhausted");
});

test("FAQ evidence answers simple reusable question", () => {
  const result = buildGroundedDecision(unknownEscalation("es"), {
    guest_message: "Cómo llego q pileta?",
  }, catalogFromSource({
    source_type: "faq",
    source_id: "faq:7",
    evidence_id: "faq.7",
    label: "Como bajo a la pileta?",
    field: "Como bajo a la pileta?",
    value: "Andá al -1 y después subí por la ventana.",
    category: "amenities",
  }));

  assert.equal(result.decision.outcome, "reply");
  assert.deepEqual(result.decision.evidence_ids, ["faq.7"]);
  assert.match(result.decision.message_body, /Andá al -1/);
});

test("structured facts take priority over contradictory FAQ evidence", () => {
  const result = buildGroundedDecision(unknownEscalation("es"), {
    guest_message: "a que hora es el check in?",
  }, catalogFromSources([
    {
      source_type: "faq",
      source_id: "faq:9",
      evidence_id: "faq.9",
      label: "A qué hora es el check-in?",
      field: "A qué hora es el check-in?",
      value: "El check-in es a las 16:00.",
      category: "arrival",
    },
    {
      source_type: "property_fact",
      source_id: "property_fact:check_in_time",
      evidence_id: "property.check_in_time",
      field: "check_in_time",
      label: "check_in_time",
      value: "15:00",
    },
  ]));

  assert.equal(result.decision.outcome, "reply");
  assert.deepEqual(result.decision.evidence_ids, ["property.check_in_time"]);
  assert.match(result.decision.message_body, /15:00/);
  assert.doesNotMatch(result.decision.message_body, /16:00/);
});

test("guide or knowledge block evidence answers operational question", () => {
  const result = buildGroundedDecision(unknownEscalation("es"), {
    guest_message: "Dónde puedo tirar la basura?",
  }, catalogFromSource({
    source_type: "knowledge_block",
    source_id: "knowledge_block:12",
    evidence_id: "guide.12",
    label: "Basura del edificio",
    field: "Basura del edificio",
    value: "Los tachos están en planta baja al lado del ascensor.",
    category: "building",
  }));

  assert.equal(result.decision.outcome, "reply");
  assert.deepEqual(result.decision.evidence_ids, ["guide.12"]);
  assert.match(result.decision.message_body, /tachos/);
});

test("authorized sensitive access info answers internet question with WiFi details", () => {
  const result = buildGroundedDecision(unknownEscalation("es"), {
    guest_message: "hay internet aca?",
  }, sensitiveAccessCatalog(true));

  assert.equal(result.override?.reason, "sufficient_evidence");
  assert.equal(result.decision.outcome, "reply");
  assert.equal(result.decision.escalation_required, false);
  assert.deepEqual(result.decision.evidence_ids.sort(), ["property.wifi_name", "property.wifi_password"].sort());
  assert.equal(result.decision.detected_intents[0].type, "wifi");
  assert.match(result.decision.message_body, /Pippa/);
  assert.match(result.decision.message_body, /Pippa123/);
  assert.doesNotMatch(result.decision.message_body, /consultando|anfitri[oó]n/i);
});

test("authorized sensitive access info answers wifi question", () => {
  const result = buildGroundedDecision(unknownEscalation("es"), {
    guest_message: "cuál es el wifi?",
  }, sensitiveAccessCatalog(true));

  assert.equal(result.decision.outcome, "reply");
  assert.equal(result.decision.escalation_required, false);
  assert.deepEqual(result.decision.evidence_ids.sort(), ["property.wifi_name", "property.wifi_password"].sort());
  assert.equal(result.decision.message_body, "Red de WiFi: Pippa. Contraseña de WiFi: Pippa123.");
});

test("authorized sensitive access info answers wifi password question", () => {
  const result = buildGroundedDecision(unknownEscalation("es"), {
    guest_message: "me pasás la clave del wifi?",
  }, sensitiveAccessCatalog(true));

  assert.equal(result.decision.outcome, "reply");
  assert.equal(result.decision.escalation_required, false);
  assert.deepEqual(result.decision.evidence_ids, ["property.wifi_password"]);
  assert.equal(result.decision.message_body, "Contraseña de WiFi: Pippa123.");
});

test("safe password request does not use wifi password evidence", () => {
  const result = buildGroundedDecision(unknownEscalation("es"), {
    guest_message: "cuál es la contraseña de la caja fuerte?",
  }, sensitiveAccessCatalog(true));

  assert.equal(result.decision.outcome, "escalate");
  assert.equal(result.decision.escalation.reason_code, "missing_sensitive_information");
  assert.deepEqual(result.decision.missing_information, ["property.safe_code"]);
  assert.deepEqual(result.decision.evidence_ids, []);
  assert.doesNotMatch(result.decision.message_body, /Pippa123/);
  const ranked = result.decision.audit.grounded_decision_builder.ranked_candidates;
  assert.ok(ranked.some((candidate: any) => String(candidate.reason_included_or_excluded).includes("sensitive_type_mismatch")));
});

test("ambiguous code request asks which sensitive access detail is needed", () => {
  const result = buildGroundedDecision(unknownEscalation("es"), {
    guest_message: "cuál es el código?",
  }, sensitiveAccessCatalog(true));

  assert.equal(result.decision.outcome, "ask_clarifying_question");
  assert.equal(result.decision.escalation_required, false);
  assert.deepEqual(result.decision.evidence_ids, []);
  assert.match(result.decision.message_body, /Qué dato necesitás/);
  assert.doesNotMatch(result.decision.message_body, /Pippa123/);
});

test("unauthorized sensitive access info does not reveal WiFi details", () => {
  const result = buildGroundedDecision(unknownEscalation("es"), {
    guest_message: "me pasás la clave del wifi?",
  }, sensitiveAccessCatalog(false));

  assert.equal(result.decision.outcome, "escalate");
  assert.equal(result.decision.escalation_required, true);
  assert.deepEqual(result.decision.evidence_ids, []);
  assert.doesNotMatch(result.decision.message_body, /Pippa|Pippa123/);
});

test("missing WiFi evidence leaves escalation as last resort", () => {
  const result = buildGroundedDecision(unknownEscalation("es"), {
    guest_message: "cuál es el wifi?",
  }, []);

  assert.equal(result.decision.outcome, "escalate");
  assert.equal(result.decision.escalation_required, true);
  assert.deepEqual(result.decision.evidence_ids, []);
});

test("parking evidence group answers with availability and instructions", () => {
  const result = buildGroundedDecision(unknownEscalation("es"), {
    guest_message: "donde estaciono?",
  }, catalogFromSources([
    {
      source_type: "property_fact",
      source_id: "property_fact:parking_available",
      evidence_id: "property.parking_available",
      field: "parking_available",
      label: "parking_available",
      value: "Hay cochera incluida",
    },
    {
      source_type: "property_fact",
      source_id: "property_fact:parking_instructions",
      evidence_id: "property.parking_instructions",
      field: "parking_instructions",
      label: "parking_instructions",
      value: "Entrá por el portón gris y usá el espacio 12",
    },
  ]));

  assert.equal(result.decision.outcome, "reply");
  assert.deepEqual(result.decision.evidence_ids.sort(), ["property.parking_available", "property.parking_instructions"].sort());
  assert.match(result.decision.message_body, /Hay cochera incluida/);
  assert.match(result.decision.message_body, /espacio 12/);
});

test("check-in evidence group can include supporting early check-in policy", () => {
  const result = buildGroundedDecision(unknownEscalation("es"), {
    guest_message: "a que hora es el check in?",
  }, catalogFromSources([
    {
      source_type: "property_fact",
      source_id: "property_fact:check_in_time",
      evidence_id: "property.check_in_time",
      field: "check_in_time",
      label: "check_in_time",
      value: "15:00",
    },
    {
      source_type: "policy",
      source_id: "policy:early_check_in_policy",
      evidence_id: "policy.early_check_in_policy",
      field: "early_check_in_policy",
      label: "early_check_in_policy",
      value: "El ingreso anticipado puede solicitarse según disponibilidad.",
    },
  ]));

  assert.equal(result.decision.outcome, "reply");
  assert.equal(result.decision.escalation_required, false);
  assert.deepEqual(result.decision.evidence_ids.sort(), ["policy.early_check_in_policy", "property.check_in_time"].sort());
  assert.match(result.decision.message_body, /15:00/);
  assert.match(result.decision.message_body, /anticipado/);
});

test("access evidence group answers with authorized instructions and code", () => {
  const result = buildGroundedDecision(unknownEscalation("es"), {
    guest_message: "como entro?",
  }, buildEvidenceCatalog([{
    toolName: "sensitive_access_info",
    result: {
      authorized: true,
      sources: [
        source({
          source_type: "property_fact",
          source_id: "property_fact:access_instructions",
          evidence_id: "property.access_instructions",
          field: "access_instructions",
          label: "access_instructions",
          value: "Entrada por costado lateral",
        }),
        source({
          source_type: "property_fact",
          source_id: "property_fact:access_code",
          evidence_id: "property.access_code",
          field: "access_code",
          label: "access_code",
          value: "4321",
        }),
      ],
    },
  }]));

  assert.equal(result.decision.outcome, "reply");
  assert.equal(result.decision.sensitive_info_used, true);
  assert.deepEqual(result.decision.evidence_ids.sort(), ["property.access_code", "property.access_instructions"].sort());
  assert.match(result.decision.message_body, /Entrada por costado lateral/);
  assert.match(result.decision.message_body, /4321/);
});

test("access code question returns code with its use and available entry instructions", () => {
  const result = buildGroundedDecision(unknownEscalation("es"), {
    guest_message: "Me puedes dar el código de acceso",
  }, buildEvidenceCatalog([{
    toolName: "sensitive_access_info",
    result: {
      authorized: true,
      sources: [
        source({
          source_type: "property_fact",
          source_id: "property_fact:access_instructions",
          evidence_id: "property.access_instructions",
          field: "access_instructions",
          label: "access_instructions",
          value: "Entrada por costado lateral. Usá la caja de llaves del pasillo para retirar la llave. Código de la caja: 4321. Luego subí al piso 3.",
        }),
      ],
    },
  }]));

  assert.equal(result.decision.outcome, "reply");
  assert.equal(result.decision.escalation_required, false);
  assert.deepEqual(result.decision.evidence_ids, ["property.access_instructions"]);
  assert.match(result.decision.message_body, /Código de la caja: 4321/);
  assert.match(result.decision.message_body, /caja de llaves/);
  assert.match(result.decision.message_body, /Entrada por costado lateral/);
  assert.doesNotMatch(result.decision.message_body, /Fuente|Source|property\.|evidence_id|source_id/i);
});

test("access question gives concise instructions and detailed request can include the full block", () => {
  const accessInstructions = [
    "Entrá por el portón lateral",
    "Tocá el timbre 3B",
    "El código de la puerta es 2468",
    "La caja de llaves está detrás de la maceta",
    "Usá la llave azul para el edificio",
    "Usá la llave plateada para el departamento",
    "El ascensor queda al fondo del pasillo",
    "El departamento está en el piso 6",
  ].join(". ");

  const concise = buildGroundedDecision(unknownEscalation("es"), {
    guest_message: "cómo entro?",
  }, catalogFromSource({
    source_type: "property_fact",
    source_id: "property_fact:access_instructions",
    evidence_id: "property.access_instructions",
    field: "access_instructions",
    label: "access_instructions",
    value: accessInstructions,
  }));

  const detailed = buildGroundedDecision(unknownEscalation("es"), {
    guest_message: "me pasás las instrucciones de acceso completas paso a paso?",
  }, catalogFromSource({
    source_type: "property_fact",
    source_id: "property_fact:access_instructions",
    evidence_id: "property.access_instructions",
    field: "access_instructions",
    label: "access_instructions",
    value: accessInstructions,
  }));

  assert.equal(concise.decision.outcome, "reply");
  assert.match(concise.decision.message_body, /Entrá por el portón lateral/);
  assert.doesNotMatch(concise.decision.message_body, /piso 6/);
  assert.equal(detailed.decision.outcome, "reply");
  assert.match(detailed.decision.message_body, /piso 6/);
});

test("access instructions answer common Spanish entry questions", () => {
  for (const guestMessage of ["cómo entro?", "cómo ingreso al depto?", "cómo se entra al edificio?", "cómo hago el ingreso?"]) {
    const result = buildGroundedDecision(unknownEscalation("es"), {
      guest_message: guestMessage,
    }, catalogFromSource({
      source_type: "property_fact",
      source_id: "property_fact:access_instructions",
      evidence_id: "property.access_instructions",
      field: "access_instructions",
      label: "access_instructions",
      value: "Entrá por el portón lateral y subí al piso 3.",
    }));

    assert.equal(result.decision.outcome, "reply", guestMessage);
    assert.equal(result.decision.escalation_required, false, guestMessage);
    assert.equal(result.decision.detected_intents[0].type, "access", guestMessage);
    assert.deepEqual(result.decision.evidence_ids, ["property.access_instructions"], guestMessage);
    assert.match(result.decision.message_body, /portón lateral/, guestMessage);
    assert.doesNotMatch(result.decision.message_body, /Fuente|Source|property\.|evidence_id|source_id/i, guestMessage);
  }
});

test("appliance guides answer washer coffee maker air conditioner oven and tv questions", () => {
  const cases = [
    {
      guest_message: "cómo uso la lavadora?",
      evidence_id: "appliance.washer",
      title: "Lavarropas",
      aliases: ["lavarropas", "lavadora", "washer"],
      content: "Usá programa rápido y agregá una ficha.",
      expected: /programa rápido/,
    },
    {
      guest_message: "cómo funciona la cafetera?",
      evidence_id: "appliance.coffee_machine",
      title: "Cafetera",
      aliases: ["cafetera", "coffee_machine", "coffee"],
      content: "Poné agua atrás y usá cápsulas chicas.",
      expected: /cápsulas/,
    },
    {
      guest_message: "cómo prendo el aire?",
      evidence_id: "appliance.air_conditioner",
      title: "Aire acondicionado",
      aliases: ["aire", "acondicionado", "air_conditioner"],
      content: "Encendelo con el control blanco y elegí modo frío.",
      expected: /control blanco/,
    },
    {
      guest_message: "cómo uso el horno?",
      evidence_id: "appliance.oven",
      title: "Horno",
      aliases: ["horno", "oven"],
      content: "Girás la perilla izquierda y esperás cinco minutos.",
      expected: /perilla izquierda/,
    },
    {
      guest_message: "cómo veo Netflix?",
      evidence_id: "appliance.tv",
      title: "TV",
      aliases: ["tv", "television", "netflix"],
      content: "Abrí Netflix desde el botón del control remoto.",
      expected: /Netflix/,
    },
  ];

  for (const item of cases) {
    const result = buildGroundedDecision(unknownEscalation("es"), {
      guest_message: item.guest_message,
    }, catalogFromSource({
      source_type: "knowledge_block",
      source_id: "knowledge_block:33",
      evidence_id: item.evidence_id,
      field: item.title,
      label: item.title,
      value: item.content,
      category: "appliances",
      appliance_name: item.title,
      aliases: item.aliases,
    }));

    assert.equal(result.decision.outcome, "reply", item.guest_message);
    assert.equal(result.decision.escalation_required, false, item.guest_message);
    assert.equal(result.decision.detected_intents[0].type, "appliance_instructions", item.guest_message);
    assert.deepEqual(result.decision.evidence_ids, [item.evidence_id], item.guest_message);
    assert.match(result.decision.message_body, item.expected, item.guest_message);
    assert.doesNotMatch(result.decision.message_body, /Fuente|Source|Источник|property\.|property_fact:|evidence_id|source_id/i, item.guest_message);
  }
});

test("missing appliance guide asks before escalating and does not expose metadata", () => {
  const result = buildGroundedDecision(unknownEscalation("es"), {
    guest_message: "cómo uso la lavadora?",
  }, []);

  assert.equal(result.decision.outcome, "ask_clarifying_question");
  assert.equal(result.decision.escalation_required, false);
  assert.match(result.decision.message_body, /No tengo instrucciones cargadas/);
  assert.match(result.decision.message_body, /anfitrión/);
  assert.doesNotMatch(result.decision.message_body, /Fuente|Source|Источник|property\.|property_fact:|evidence_id|source_id/i);
});

test("recommendation evidence group answers with name and address", () => {
  const result = buildGroundedDecision(unknownEscalation("es"), {
    guest_message: "recomendame un cafe cerca",
  }, catalogFromSources([
    {
      source_type: "recommendation",
      source_id: "recommendation:3",
      evidence_id: "recommendation.3.name",
      field: "name",
      label: "Café Roma",
      value: "Café Roma",
      category: "cafe",
    },
    {
      source_type: "recommendation",
      source_id: "recommendation:3:address",
      evidence_id: "recommendation.3.address",
      field: "address",
      label: "Dirección",
      value: "Calle 1 123",
      category: "cafe",
    },
  ]));

  assert.equal(result.decision.outcome, "reply");
  assert.deepEqual(result.decision.evidence_ids.sort(), ["recommendation.3.address", "recommendation.3.name"].sort());
  assert.match(result.decision.message_body, /Café Roma/);
  assert.match(result.decision.message_body, /Calle 1 123/);
});

test("unauthorized sensitive evidence is filtered before grouped replies", () => {
  const result = buildGroundedDecision(unknownEscalation("es"), {
    guest_message: "como entro?",
  }, buildEvidenceCatalog([{
    toolName: "sensitive_access_info",
    result: {
      authorized: false,
      sources: [
        source({
          source_type: "property_fact",
          source_id: "property_fact:access_code",
          evidence_id: "property.access_code",
          field: "access_code",
          label: "access_code",
          value: "4321",
        }),
      ],
    },
  }]));

  assert.equal(result.decision.outcome, "escalate");
  assert.doesNotMatch(result.decision.message_body, /4321/);
  assert.deepEqual(result.decision.evidence_ids, []);
});

test("policy evidence that requires approval proposes a narrow escalation without promising", () => {
  const result = buildGroundedDecision(unknownEscalation("es"), {
    guest_message: "Puedo invitar visitas?",
  }, catalogFromSource({
    source_type: "policy",
    source_id: "policy:visitors",
    evidence_id: "policy.visitors",
    field: "visitors",
    label: "visitors",
    value: "approval_required",
  }));

  assert.equal(result.override?.reason, "approval_required");
  assert.equal(result.decision.outcome, "propose_action");
  assert.equal(result.decision.escalation_required, true);
  assert.deepEqual(result.decision.evidence_ids, ["policy.visitors"]);
  assert.match(result.decision.message_body, /requiere aprobación/);
  assert.doesNotMatch(result.decision.message_body, /aprobado|confirmado/i);
});

test("approved recommendation evidence answers recommendation request", () => {
  const result = buildGroundedDecision(unknownEscalation("es"), {
    guest_message: "Tenés un café cerca para recomendar?",
  }, catalogFromSource({
    source_type: "recommendation",
    source_id: "recommendation:3",
    evidence_id: "recommendation.3",
    label: "Café Roma",
    field: "Café Roma",
    value: "Buen café a dos cuadras.",
    category: "cafe",
    address: "Calle 1 123",
    google_maps_url: "https://maps.example/cafe",
  }));

  assert.equal(result.decision.outcome, "reply");
  assert.deepEqual(result.decision.evidence_ids, ["recommendation.3"]);
  assert.match(result.decision.message_body, /Café Roma/);
});

test("generic recommendation categories answer with approved evidence", () => {
  const result = buildGroundedDecision(unknownEscalation("es"), {
    guest_message: "Hay alguna farmacia cerca?",
  }, catalogFromSource({
    source_type: "recommendation",
    source_id: "recommendation:8",
    evidence_id: "recommendation.8",
    label: "Farmacia Central",
    field: "Farmacia Central",
    value: "Abre hasta tarde.",
    category: "pharmacy",
    address: "Av. Principal 123",
  }));

  assert.equal(result.decision.outcome, "reply");
  assert.deepEqual(result.decision.evidence_ids, ["recommendation.8"]);
  assert.match(result.decision.message_body, /Farmacia Central/);
  assert.match(result.decision.message_body, /Av\. Principal 123/);
});

test("recommendation request without evidence does not invent places", () => {
  const result = buildGroundedDecision(unknownEscalation("es"), {
    guest_message: "Dónde puedo comer cerca?",
  }, []);

  assert.equal(result.decision.outcome, "ask_clarifying_question");
  assert.equal(result.decision.escalation_required, false);
  assert.deepEqual(result.decision.evidence_ids, []);
  assert.match(result.decision.message_body, /No tengo recomendaciones guardadas/);
  assert.doesNotMatch(result.decision.message_body, /Café|Restaurante|Farmacia|Supermercado/);
});

test("restaurant request with saved recommendations replies without clarification", () => {
  const result = buildGroundedDecision(unknownEscalation("es"), {
    guest_message: "Restaurantes",
  }, catalogFromSources([
    {
      source_type: "recommendation",
      source_id: "recommendation:10",
      evidence_id: "recommendation.10",
      label: "La Barra",
      field: "La Barra",
      value: "Parrilla a tres cuadras.",
      category: "food",
      address: "Calle Falsa 123",
    },
    {
      source_type: "recommendation",
      source_id: "recommendation:11",
      evidence_id: "recommendation.11",
      label: "Pasta Centro",
      field: "Pasta Centro",
      value: "Pastas caseras cerca del edificio.",
      category: "restaurant",
      address: "Av. Centro 456",
    },
  ]));

  assert.equal(result.decision.outcome, "reply");
  assert.equal(result.decision.escalation_required, false);
  assert.deepEqual(result.decision.evidence_ids.sort(), ["recommendation.10", "recommendation.11"].sort());
  assert.match(result.decision.message_body, /La Barra/);
  assert.match(result.decision.message_body, /Pasta Centro/);
  assert.doesNotMatch(result.decision.message_body, /prefer|aclar/i);
  assert.equal(result.decision.audit.grounded_decision_builder.clarification_attempts.count, 0);
});

test("restaurant request does not use supermarket recommendation as restaurant evidence", () => {
  const result = buildGroundedDecision(unknownEscalation("es"), {
    guest_message: "Restaurantes para comer",
  }, catalogFromSources([
    {
      source_type: "recommendation",
      source_id: "recommendation:41",
      evidence_id: "recommendation.41",
      label: "Mercado Verde",
      field: "Mercado Verde",
      value: "Supermercado para compras rápidas.",
      category: "supermarket",
      address: "Mercado 41",
    },
  ]));

  assert.notEqual(result.decision.outcome, "reply");
  assert.deepEqual(result.decision.evidence_ids, []);
  assert.doesNotMatch(result.decision.message_body, /Mercado Verde/);
  assert.ok(result.decision.audit.grounded_decision_builder.ranked_candidates.some((candidate: any) =>
    String(candidate.reason_included_or_excluded).includes("recommendation_category_mismatch"),
  ));
});

test("italian restaurant request offers saved restaurants without inventing italian match", () => {
  const result = buildGroundedDecision(unknownEscalation("es"), {
    guest_message: "Tenés un restaurante italiano?",
  }, catalogFromSources([
    {
      source_type: "recommendation",
      source_id: "recommendation:51",
      evidence_id: "recommendation.51",
      label: "La Barra",
      field: "La Barra",
      value: "Parrilla a tres cuadras.",
      category: "restaurant",
      address: "Calle Falsa 123",
    },
  ]));

  assert.equal(result.decision.outcome, "reply");
  assert.deepEqual(result.decision.evidence_ids, ["recommendation.51"]);
  assert.match(result.decision.message_body, /No tengo una recomendación específica de italiano registrada/);
  assert.match(result.decision.message_body, /La Barra/);
});

test("neutral preference after recommendation question chooses saved recommendations instead of asking again", () => {
  const result = buildGroundedDecision(unknownEscalation("es"), {
    guest_message: "me da igual, lo que recomiendes",
    conversation_history: [
      { sender: "guest", body: "Qué me recomendás cerca del departamento?" },
      { sender: "ai", body: "¿Preferís restaurante, café, supermercado, farmacia u otro lugar?" },
    ],
  }, catalogFromSources([
    {
      source_type: "recommendation",
      source_id: "recommendation:1",
      evidence_id: "recommendation.1",
      label: "Café Roma",
      field: "Café Roma",
      value: "Buen café a dos cuadras.",
      category: "cafe",
      address: "Calle 1 123",
    },
    {
      source_type: "recommendation",
      source_id: "recommendation:2",
      evidence_id: "recommendation.2",
      label: "Mercado Verde",
      field: "Mercado Verde",
      value: "Supermercado chico para compras rápidas.",
      category: "grocery",
      address: "Calle 2 456",
    },
    {
      source_type: "recommendation",
      source_id: "recommendation:3",
      evidence_id: "recommendation.3",
      label: "La Esquina",
      field: "La Esquina",
      value: "Restaurante simple para cenar.",
      category: "food",
      address: "Calle 3 789",
    },
  ]));

  assert.equal(result.decision.outcome, "reply");
  assert.equal(result.decision.escalation_required, false);
  assert.deepEqual(result.decision.evidence_ids.sort(), ["recommendation.1", "recommendation.2", "recommendation.3"].sort());
  assert.match(result.decision.message_body, /Café Roma/);
  assert.match(result.decision.message_body, /Mercado Verde/);
  assert.match(result.decision.message_body, /La Esquina/);
  assert.doesNotMatch(result.decision.message_body, /prefer/i);
});

test("cualquiera after restaurant clarification chooses saved recommendations", () => {
  const result = buildGroundedDecision(aiClarification("es"), {
    guest_message: "Cualquiera",
    conversation_history: [
      { sender: "guest", body: "Lugares para comer cerca?" },
      { sender: "ai", body: "¿Preferís restaurante, café, supermercado, farmacia u otro lugar?" },
    ],
  }, catalogFromSources([
    {
      source_type: "recommendation",
      source_id: "recommendation:21",
      evidence_id: "recommendation.21",
      label: "Comedor Norte",
      field: "Comedor Norte",
      value: "Restaurante simple para almorzar.",
      category: "food",
      address: "Norte 21",
    },
  ]));

  assert.equal(result.decision.outcome, "reply");
  assert.equal(result.decision.escalation_required, false);
  assert.deepEqual(result.decision.evidence_ids, ["recommendation.21"]);
  assert.match(result.decision.message_body, /Comedor Norte/);
  assert.doesNotMatch(result.decision.message_body, /prefer|tipo|aclar/i);
  assert.equal(result.decision.audit.grounded_decision_builder.clarification_attempts.count, 1);
});

test("after two recommendation clarifications uses best available recommendations instead of asking again", () => {
  const result = buildGroundedDecision(aiClarification("es"), {
    guest_message: "me da igual",
    conversation_history: [
      { sender: "guest", body: "Restaurantes?" },
      { sender: "ai", body: "¿Preferís restaurante, café, supermercado, farmacia u otro lugar?" },
      { sender: "guest", body: "No sé" },
      { sender: "ai", body: "¿Buscás algo para comer, tomar café o hacer compras?" },
    ],
    decision_settings: {
      max_clarification_attempts: 2,
    },
  }, catalogFromSources([
    {
      source_type: "recommendation",
      source_id: "recommendation:31",
      evidence_id: "recommendation.31",
      label: "Bistró Sur",
      field: "Bistró Sur",
      value: "Buen lugar para cenar.",
      category: "restaurant",
      address: "Sur 31",
    },
  ]));

  assert.equal(result.decision.outcome, "reply");
  assert.equal(result.decision.escalation_required, false);
  assert.deepEqual(result.decision.evidence_ids, ["recommendation.31"]);
  assert.match(result.decision.message_body, /Bistró Sur/);
  assert.doesNotMatch(result.decision.message_body, /\?/);
  assert.equal(result.decision.audit.grounded_decision_builder.clarification_attempts.count, 2);
});

test("after two recommendation clarifications without evidence escalates instead of asking a third time", () => {
  const result = buildGroundedDecision(aiClarification("es"), {
    guest_message: "cualquiera",
    conversation_history: [
      { sender: "guest", body: "Restaurantes?" },
      { sender: "ai", body: "¿Preferís restaurante, café, supermercado, farmacia u otro lugar?" },
      { sender: "guest", body: "No sé" },
      { sender: "ai", body: "¿Buscás algo para comer, tomar café o hacer compras?" },
    ],
    decision_settings: {
      max_clarification_attempts: 2,
    },
  }, []);

  assert.equal(result.decision.outcome, "escalate");
  assert.equal(result.decision.escalation_required, true);
  assert.deepEqual(result.decision.evidence_ids, []);
  assert.equal(result.decision.escalation.reason_code, "clarification_limit_reached");
  assert.equal(result.decision.audit.grounded_decision_builder.clarification_attempts.count, 2);
  assert.equal(result.decision.audit.grounded_decision_builder.grounded_decision_result.reason_if_null, "clarification_attempts_exhausted");
});

test("partial evidence asks for clarification", () => {
  const result = buildGroundedDecision(unknownEscalation("en"), {
    guest_message: "What are the building hours?",
  }, buildEvidenceCatalog([{
    toolName: "property_brain",
    result: [
      source({
        source_type: "knowledge_block",
        source_id: "knowledge_block:1",
        evidence_id: "guide.1",
        label: "Pool hours",
        value: "The pool is open from 9 to 18.",
        category: "building",
      }),
      source({
        source_type: "knowledge_block",
        source_id: "knowledge_block:2",
        evidence_id: "guide.2",
        label: "Gym hours",
        value: "The gym is open from 8 to 20.",
        category: "building",
      }),
    ],
  }]));

  assert.equal(result.override?.reason, "partial_evidence");
  assert.equal(result.decision.outcome, "ask_clarifying_question");
  assert.equal(result.decision.escalation_required, false);
  assert.deepEqual(result.decision.evidence_ids, ["guide.1", "guide.2"]);
});

test("no evidence leaves the escalation untouched", () => {
  const original = unknownEscalation("en");
  const result = buildGroundedDecision(original, {
    guest_message: "What color is the front door?",
  }, []);

  assert.equal(result.override, null);
  assert.equal(result.decision.outcome, "escalate");
  assert.equal(result.decision.audit.grounded_decision_builder.evidence_catalog_size, 0);
  assert.equal(result.decision.audit.grounded_decision_builder.grounded_decision_result.reason_if_null, "no_ranked_candidates");
  assert.equal(result.decision.audit.grounded_decision_builder.final_decision_source.model, true);
});

test("sufficient evidence never remains unknown and evidence ids are present", () => {
  const result = buildGroundedDecision(unknownEscalation("en"), {
    guest_message: "Can you send the address?",
  }, catalogFromSource({
    source_type: "property_fact",
    source_id: "property_fact:address",
    evidence_id: "property.address",
    field: "address",
    label: "address",
    value: "123 Test Street",
  }));

  assert.equal(result.decision.outcome, "reply");
  assert.notEqual(result.decision.detected_intents[0].type, "unknown");
  assert.deepEqual(result.decision.evidence_ids, ["property.address"]);
  assert.ok(result.decision.audit.grounded_decision_builder.decision_scores.answer_confidence >= 75);
  assert.ok(result.decision.audit.grounded_decision_builder.decision_scores.evidence_relevance_score >= 75);
  assert.ok(result.decision.audit.grounded_decision_builder.decision_scores.safety_score >= 75);
});

test("high threshold does not force clarification when one evidence group can answer", () => {
  const result = buildGroundedDecision(unknownEscalation("es"), {
    guest_message: "a que hora puedo entrar al depto?",
    decision_settings: {
      high_score_threshold: 95,
      medium_score_threshold: 40,
      safety_score_threshold: 75,
      max_clarification_attempts: 2,
    },
  }, catalogFromSource({
    source_type: "property_fact",
    source_id: "property_fact:check_in_time",
    evidence_id: "property.check_in_time",
    field: "check_in_time",
    label: "check_in_time",
    value: "15:00",
  }));

  const audit = result.decision.audit.grounded_decision_builder;
  assert.equal(result.decision.outcome, "reply");
  assert.deepEqual(result.decision.evidence_ids, ["property.check_in_time"]);
  assert.match(result.decision.message_body, /15:00/);
  assert.equal(audit.score_thresholds.high_score_threshold, 95);
  assert.equal(audit.grounded_decision_result.override_type, "sufficient_evidence");
});

test("custom max clarification attempts uses best available evidence when possible", () => {
  const result = buildGroundedDecision(unknownEscalation("es"), {
    guest_message: "a que hora puedo ir?",
    decision_settings: {
      high_score_threshold: 75,
      medium_score_threshold: 40,
      safety_score_threshold: 75,
      max_clarification_attempts: 1,
    },
    clarification_attempts: {
      ambiguous_request: 1,
      ambiguous_time: 1,
      total: 1,
    },
  }, catalogFromSources([
    {
      source_type: "property_fact",
      source_id: "property_fact:check_in_time",
      evidence_id: "property.check_in_time",
      field: "check_in_time",
      label: "check_in_time",
      value: "15:00",
    },
    {
      source_type: "property_fact",
      source_id: "property_fact:check_out_time",
      evidence_id: "property.check_out_time",
      field: "check_out_time",
      label: "check_out_time",
      value: "11:00",
    },
  ]));

  const audit = result.decision.audit.grounded_decision_builder;
  assert.equal(result.decision.outcome, "reply");
  assert.equal(result.decision.escalation_required, false);
  assert.notDeepEqual(result.decision.evidence_ids, []);
  assert.equal(audit.clarification_attempts.max, 1);
  assert.equal(audit.grounded_decision_result.override_type, "sufficient_evidence");
});

function unknownEscalation(language: string) {
  return {
    outcome: "escalate",
    decision: "escalate",
    language,
    message_body: "Lo estoy consultando con el anfitrión.",
    detected_intents: [{ type: "unknown", status: "escalated" }],
    evidence_ids: [],
    escalation_required: true,
    escalation: {
      required: true,
      reason_code: "unknown",
      summary_for_host: "No se pudo responder.",
    },
    confidence: 0.3,
    safety_flags: ["fallback"],
  };
}

function aiClarification(language: string) {
  return {
    outcome: "ask_clarifying_question",
    decision: "ask_clarifying_question",
    language,
    message_body: "¿Preferís restaurante, café, supermercado, farmacia u otro lugar?",
    detected_intents: [{ type: "recommendation", status: "needs_clarification" }],
    evidence_ids: [],
    escalation_required: false,
    escalation: {
      required: false,
      reason_code: null,
      summary_for_host: null,
    },
    confidence: 0.55,
    safety_flags: [],
  };
}

function catalogFromSource(data: Record<string, unknown>) {
  return buildEvidenceCatalog([{ toolName: "property_brain", result: source(data) }]);
}

function catalogFromSources(items: Array<Record<string, unknown>>) {
  return buildEvidenceCatalog([{ toolName: "property_brain", result: items.map(source) }]);
}

function sensitiveAccessCatalog(authorized: boolean) {
  return buildEvidenceCatalog([{
    toolName: "sensitive_access_info",
    result: authorized
      ? {
          authorized: true,
          sources: [
            source({
              source_type: "property_fact",
              source_id: "property_fact:wifi_name",
              evidence_id: "property.wifi_name",
              field: "wifi_name",
              label: "wifi_name",
              value: "Pippa",
            }),
            source({
              source_type: "property_fact",
              source_id: "property_fact:wifi_password",
              evidence_id: "property.wifi_password",
              field: "wifi_password",
              label: "wifi_password",
              value: "Pippa123",
            }),
            source({
              source_type: "property_fact",
              source_id: "property_fact:access_instructions",
              evidence_id: "property.access_instructions",
              field: "access_instructions",
              label: "access_instructions",
              value: "Entrada por costado lateral",
            }),
          ],
        }
      : {
          authorized: false,
          reason: "guest_not_authorized",
          sources: [],
        },
  }]);
}

function propertyFact(field: string, evidenceId: string, value: string) {
  return {
    source_type: "property_fact",
    source_id: `property_fact:${field}`,
    evidence_id: evidenceId,
    field,
    label: field,
    value,
  };
}

function source(data: Record<string, unknown>) {
  return {
    type: data.source_type,
    title: data.label,
    content: data.value,
    excerpt: data.value,
    ...data,
  };
}
