import assert from "node:assert/strict";
import test from "node:test";
import { PropertyImportSchema, PROPERTY_IMPORT_SYSTEM_PROMPT } from "./property-import-schema.js";

test("property import keeps structured sections separate from general notes", () => {
  const result = PropertyImportSchema.parse({
    property: {
      wifi_name: "Pippa",
      wifi_password: "Pippa123",
      checkout_instructions: "Dejá las llaves sobre la mesa.",
      ai_general_notes: "La pileta abre de 10:00 a 20:00.",
    },
    appliance_guides: [
      {
        title: "Lavarropas",
        content: "Usá una ficha y el programa rápido.",
      },
    ],
    faqs: [],
    recommendations: [
      {
        name: "Birkin Coffee Bar",
        category: "cafe",
        description: "A seis minutos caminando.",
      },
    ],
  });

  assert.equal(result.property.wifi_name, "Pippa");
  assert.equal(result.property.checkout_instructions, "Dejá las llaves sobre la mesa.");
  assert.equal(result.appliance_guides[0].title, "Lavarropas");
  assert.equal(result.recommendations[0].category, "cafe");
});

test("property import prompt forbids dumping appliance and checkout details into notes", () => {
  assert.match(PROPERTY_IMPORT_SYSTEM_PROMPT, /Never put appliance instructions in ai_general_notes/);
  assert.match(PROPERTY_IMPORT_SYSTEM_PROMPT, /checkout_instructions/);
  assert.match(PROPERTY_IMPORT_SYSTEM_PROMPT, /Use ai_general_notes only/);
});
