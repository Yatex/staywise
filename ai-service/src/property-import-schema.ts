import { z } from "zod";

const nullableText = z.string().nullable().optional();

export const PropertyImportSchema = z.object({
  property: z.object({
    name: nullableText,
    address: nullableText,
    internal_nickname: nullableText,
    check_in_time: nullableText,
    checkout_time: nullableText,
    checkout_instructions: nullableText,
    wifi_name: nullableText,
    wifi_password: nullableText,
    house_rules: nullableText,
    access_instructions: nullableText,
    parking_instructions: nullableText,
    emergency_information: nullableText,
    owner_contact_instructions: nullableText,
    ai_general_notes: nullableText,
    tag_list: nullableText,
  }),
  appliance_guides: z.array(
    z.object({
      title: z.string(),
      content: z.string(),
      youtube_url: nullableText,
    }),
  ).default([]),
  faqs: z.array(
    z.object({
      question: z.string(),
      answer: z.string(),
      category: nullableText,
    }),
  ).default([]),
  recommendations: z.array(
    z.object({
      name: z.string(),
      category: z.enum(["restaurant", "cafe", "supermarket", "pharmacy", "attraction", "transport", "other"]),
      description: nullableText,
      address: nullableText,
      google_maps_url: nullableText,
      website_url: nullableText,
      phone_number: nullableText,
      owner_note: nullableText,
      distance_or_walking_time: nullableText,
    }),
  ).default([]),
  source_summary: nullableText,
});

export const PROPERTY_IMPORT_SYSTEM_PROMPT = [
  "You extract short-term rental property setup data for Ayla Manager.",
  "Extract only information explicitly present in the uploaded document or image. The current property is context only; do not echo existing fields unless the upload confirms or updates them.",
  "Do not invent facts, amenities, rules, prices, availability, policies, addresses, codes, passwords, recommendations, or URLs.",
  "Preserve the owner's language for long text fields and concrete values exactly.",
  "Normalize check-in and checkout times as short readable values like '15:00' or '11:00'.",
  "Map arrival, entrance, concierge, lockbox, keys, door codes, floor, and building-entry instructions to access_instructions.",
  "Map garage, parking, remote control, underground parking, street parking, and vehicle restrictions to parking_instructions.",
  "Map network name and WiFi password only to wifi_name and wifi_password.",
  "Map departure, checkout procedure, keys, trash, lights, climate control, and leaving instructions to checkout_instructions.",
  "Create appliance_guides for instructions about washing machines, dryers, air conditioning, heating equipment, TVs, ovens, coffee makers, dishwashers, and other appliances. Never put appliance instructions in ai_general_notes.",
  "Create recommendations only for places explicitly approved or recommended by the host.",
  "Use ai_general_notes only for general stay information that does not fit any dedicated property field, appliance guide, FAQ, or recommendation.",
  "Create FAQs only when the source contains a reusable guest question and a clear answer, or when a clear instruction can naturally become a reusable FAQ.",
  "Return null, empty arrays, or omit fields that are not supported by the source.",
].join("\n");
