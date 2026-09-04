# Ayla: resumen funcional y técnico para otra AI (legacy)

> Deprecated: this document describes the former guest automation product. It remains only for historical context. The current runtime is documented in `COPILOT_ARCHITECTURE.md`.

> Snapshot documentado: 20 de agosto de 2026, rama `main`, commit `41d3c1f`.
> Este documento describe el código actual. No debe asumirse que el README histórico refleja todos los cambios recientes.

## 1. Qué es Ayla

Ayla Manager es un SaaS multi-tenant para dueños y administradores de alojamientos temporarios. Su interfaz principal es un panel Rails y su canal conversacional es WhatsApp mediante Twilio.

El producto cubre cuatro experiencias:

1. **Configuración del alojamiento:** el dueño carga propiedades, información operativa, FAQs, guías, electrodomésticos, recomendaciones, datos sensibles y co-hosts.
2. **Asistente para huéspedes:** el huésped abre WhatsApp desde un link o QR específico de una propiedad, hace preguntas y recibe respuestas fundamentadas en el contenido de esa propiedad.
3. **Operación del dueño:** cuando se necesita una acción humana, Ayla crea un pedido, consulta, alerta o salida y permite revisarlo/responderlo desde el panel o desde un workflow operativo de WhatsApp.
4. **Auditoría:** administradores pueden inspeccionar AI Trace, errores operativos, tools, evidencias, decisiones, validaciones y entregas de WhatsApp.

La regla de arquitectura central es:

```text
Node/AI interpreta, recupera evidencia y propone una decisión.
Rails autoriza, persiste, ejecuta efectos, envía WhatsApp y audita.
```

La AI no tiene acceso directo a PostgreSQL. Obtiene información por tools internas firmadas y limitadas a la conversación que Rails ya resolvió.

## 2. Stack y procesos

### Aplicación web

- Ruby 3.0.x y Rails 7.1.
- PostgreSQL.
- ERB, Turbo, Stimulus y Tailwind CSS.
- Puma como servidor.
- Active Job para trabajos diferidos; la configuración concreta del adaptador depende del entorno.
- BCrypt para autenticación propia por sesión.
- Stripe para suscripciones.
- Twilio para WhatsApp.
- Resend para correo transaccional.
- Sentry y una tabla propia de errores operativos.

### AI service

- Node.js 20.6 o superior en producción.
- TypeScript.
- Vercel AI SDK (`ai`) y Zod.
- OpenAI a través de AI Gateway; modelo configurable con `AI_MODEL`, actualmente pensado para `openai/gpt-5-mini`.
- Sentry independiente del proyecto Rails.

### Límites de despliegue relevantes

- Rails y `ai-service` son servicios separados.
- Rails llama `POST /decide` en Node.
- Node llama tools privadas de Rails en `/internal/ai/tools/*`.
- Ambos comparten exactamente el mismo `AI_SERVICE_TOKEN`.
- En una instancia Rails de 512 MB se recomienda `WEB_CONCURRENCY=1` y `RAILS_MAX_THREADS=5`.
- `GET /up` es el health check Rails; `GET /health` es el health check Node.

## 3. Mapa del repositorio

```text
app/
  controllers/              Panel, autenticación, webhooks y tools internas
  models/                   Dominio y persistencia
  services/ai/              Contexto, llamada remota, validación, evidencia, fallback
  services/whatsapp/        Routing, Twilio, workflow del dueño y Observer
  services/translation/     DeepL / AI provider y traducción de respuestas
  services/guest_requests/  Creación/actualización de OwnerTasks
  services/alerts/          Alertas operativas
  services/checkout_events/ Salidas confirmadas
  services/observer/        Registro de actividad para Observer
  jobs/                     Notificaciones diferidas
  views/                    Panel ERB
ai-service/src/
  server.ts                         Servidor y orquestación AI/tools
  decision-schema.ts                Contrato público de decisión
  decision-system-prompt.ts         Prompt principal y prompt de revisión
  rails-tool-client.ts              Cliente de tools Rails
  evidence-catalog.ts               Catálogo normalizado de evidencia
  grounded-decision-builder.ts      Revisión/override grounded
  operational-emergency-classifier.ts Guardrail de emergencias
  conversational-classifier.ts      Bypass determinístico para conversación social
  guest-message-sanitizer.ts        Limpieza del texto visible al huésped
  technical-fallback-diagnostic.ts  Diagnóstico de fallbacks
test/                        Suite Rails
ai-service/src/*.test.ts     Suite Node
```

## 4. Modelo multi-tenant y permisos

### Account

Es el tenant. Agrupa usuarios, propiedades, huéspedes, OwnerTasks, salidas, sesiones del dueño, actividad Observer, suscripción, configuración AI y errores.

Contiene, entre otras cosas:

- activación y tono de Ayla;
- automatizaciones permitidas;
- número de WhatsApp del dueño;
- Observer mode;
- idioma preferido para contenido dirigido al dueño;
- límites de propiedades por plan u override administrativo.

### User

Usuario del panel con roles `owner`, `admin` o `member`.

- `admin_like?` controla las secciones administrativas.
- Los índices normales de propiedades y conversaciones muestran únicamente la cuenta propia.
- Un admin puede abrir el **show** de una propiedad o conversación ajena desde AI Trace para auditarla.
- Una propiedad ajena se muestra en modo lectura; no se habilita edición cruzada.
- Pedidos, consultas y alertas comunes siguen aislados por cuenta.

### CoHost

Existe un co-host opcional por propiedad. Tiene número de WhatsApp propio, propiedades asignadas, preferencias Observer y drafts de respuesta.

- El dueño ve todas las propiedades de su cuenta.
- El co-host solamente puede operar las propiedades que tiene asignadas.
- La resolución de un número de host exige un único actor; una identidad ambigua se rechaza.

### Suscripciones

`Subscription` define los límites actuales de propiedades:

- Starter: 3
- Growth: 10
- Business: 20
- Scale: 35
- Pro: 60

Puede existir un override administrativo que cambia únicamente el límite efectivo, no el plan ni la facturación de Stripe.

## 5. Entidades principales

| Entidad | Significado actual |
|---|---|
| `Property` | Alojamiento de una cuenta. Tiene token público, estado, configuración AI, información operativa y co-host opcional. |
| `Guest` | Huésped identificado por teléfono dentro de una cuenta; puede tener datos de reserva y propiedad actual. |
| `Conversation` | Conversación WhatsApp vinculada en cada momento a un huésped y propiedad. |
| `Message` | Mensaje de `guest`, `ai`, `owner` o `system`, con snapshot de `account_id` y `property_id`. |
| `OwnerTask` | Una necesidad humana pendiente; no representa un mensaje. Se persiste en la tabla histórica `guest_requests`. |
| `Alert` | Riesgo o incidente operativo, separado de un OwnerTask normal. |
| `CheckoutEvent` | Confirmación de que el huésped ya salió; tiene idempotencia por reserva/mensaje. |
| `OwnerWhatsappSession` | Estado del workflow operativo del dueño en WhatsApp. No se usa para Observer. |
| `OwnerReplyDraft` | Respuesta preparada, original/traducida, con estado y confirmación. |
| `ConversationObserverActivity` | Actividad agrupada para avisos Observer sin sesión conversacional. |
| `AIDecisionLog` | AI Trace completo: request, response, tools, evidencia, validaciones, fallback y WhatsApp. |
| `OperationalError` | Error sanitizado visible en el panel administrativo. |
| `MessageTranslation` | Traducción persistida de un mensaje sin modificar el original. |

## 6. Fuentes de conocimiento de una propiedad

La información que Ayla puede recuperar está separada así:

### Campos de Property

- nombre, alias y dirección;
- check-in y check-out;
- instrucciones de salida;
- WiFi;
- reglas;
- acceso;
- estacionamiento;
- emergencia;
- contacto del anfitrión;
- notas generales para Ayla;
- tags y estado.

### FAQ

- Pregunta, respuesta, categoría, estado y fuente.
- Estados: `pending_review`, `approved`, `archived`.
- Solamente FAQs aprobadas y activas forman parte del scope normal de recuperación.
- Pueden crearse manualmente, copiarse, aprenderse de una respuesta del dueño o cargarse en varias propiedades mediante el flujo masivo.

### KnowledgeBlock

Guías extensas por categoría: check-in, checkout, WiFi, electrodomésticos, reglas, amenities, acceso, transporte, emergencias y notas. Puede contener `youtube_url`.

### Recommendation

Recomendaciones locales aprobadas y asociadas a una propiedad: categoría, nombre, descripción, dirección, distancia, Maps, web y teléfono.

### PropertySensitiveDatum

Datos sensibles cifrados: códigos de caja fuerte, lockbox, puerta, portón, alarma, edificio, ubicación de llaves y passwords de dispositivos.

Estos datos solamente se entregan si `ReservationAuthorization` autoriza el acceso del huésped para esa propiedad/reserva.

## 7. Routing de mensajes entrantes de WhatsApp

Punto de entrada:

```text
POST /webhooks/whatsapp
  -> Webhooks::WhatsappController#create
  -> validación de firma Twilio
  -> Whatsapp::IncomingMessageHandler
```

El parser normaliza `From`, `To`, `Body`, `MessageSid`, multimedia, respuestas interactivas y tokens del tipo:

```text
Ayla stay <public_token>
```

### Prioridad real

```text
1. ¿El teléfono pertenece a un dueño/co-host autorizado?
   Sí -> OwnerInboundMessageHandler y termina el routing.

2. Si no es host, ¿hay un token explícito válido?
   Sí -> resuelve esa propiedad.

3. Si no hay token, usa la conversación WhatsApp más reciente del teléfono.

4. Resuelve/crea Guest y Conversation.

5. Persiste Message del huésped.

6. Si AI está activa, ejecuta el flujo AI.
```

Consecuencia deliberada: **un número configurado como dueño o co-host no puede actuar como huésped**. El rol host gana antes de mirar tokens o preguntas. Si escribe algo que no es un comando operativo, Ayla le explica que ese número es de anfitrión y le indica usar `MENÚ`, `AYUDA` u otro teléfono para probar como huésped.

### Identidad de conversación

`Conversation` es única por `channel + channel_participant`. En WhatsApp eso equivale, en la práctica, a una conversación por número.

- Si el mismo teléfono usa un token de otra propiedad, la conversación puede relinkearse al nuevo `Guest`/`Property`.
- Los mensajes guardan snapshots de cuenta y propiedad para conservar el historial multi-tenant.
- Los controladores filtran esos snapshots para evitar que un tenant vea mensajes históricos de otro.
- Los `MessageSid` de Twilio se usan para idempotencia y evitar duplicados.

Este diseño es importante: no existe un chat independiente por cada propiedad para un mismo teléfono; existe un hilo WhatsApp que cambia de contexto con un token explícito.

## 8. Flujo del huésped de extremo a extremo

```text
Mensaje Twilio
  -> identificar propiedad/huésped/conversación
  -> persistir Message guest
  -> AI::ContextBuilder
  -> AI::DecisionService POST /decide
  -> Node ejecuta tools Rails
  -> modelo + grounded review/guardrails
  -> Rails DecisionValidator
  -> persistir OwnerTask / Alert / CheckoutEvent si corresponde
  -> enviar respuesta de Ayla por Twilio
  -> completar AIDecisionLog
```

Casos especiales:

- Un mensaje vacío sin interacción ni media se ignora.
- Un mensaje solamente multimedia se guarda, pero no se manda a la AI.
- El mensaje inicial del QR/token puede marcarse como `routing_init`.
- Si la cuenta o propiedad tiene AI apagada, el mensaje queda registrado sin decisión ni respuesta automática.
- Si la acción es `no_action`, no se envía respuesta.

## 9. Contexto enviado desde Rails a Node

`AI::ContextBuilder` envía:

- correlation ID;
- `account_id`, `property_id`, `conversation_id`;
- último mensaje del huésped;
- idioma persistido del huésped como fallback;
- idioma del dueño;
- nombre de la propiedad;
- autorización/resumen de reserva;
- configuración de tono/objetivo/estilo;
- settings de decisión;
- últimos 12 mensajes de la conversación;
- OwnerTasks abiertos de esa conversación (`id`, tipo, título, categoría, fecha);
- endpoint de tools;
- `decision_context_id` firmado y con TTL de 10 minutos;
- reglas de seguridad.

No se debe pasar un `property_id` libre desde un request HTTP a una tool. Node devuelve el `decision_context_id`; Rails lo verifica y reconstruye conversación, mensaje, huésped, propiedad y cuenta.

## 10. Tools disponibles

Endpoints Rails bajo `/internal/ai/tools`:

| Tool | Propósito |
|---|---|
| `property_brain` | Búsqueda principal de facts, FAQs, guías, políticas y recomendaciones. |
| `sensitive_access_info` | WiFi, códigos, llaves y acceso, solamente si está autorizado. |
| `guest_context` | Contexto del huésped, propiedad y reserva. |
| `stay_facts` | Facts concretos de la estadía/reserva. |
| `search_property_knowledge` | Búsqueda explícita en conocimiento de propiedad. |
| `approved_recommendations` | Recomendaciones locales activas. |
| `access_instructions` | Instrucciones de acceso autorizadas. |
| `property_policy` | Política de una categoría. |
| `escalation_draft` | Estructura un borrador de escalamiento; no persiste por sí sola. |

Para mensajes sustantivos, Node intenta de forma obligatoria `guest_context`, `stay_facts` y `property_brain`. `sensitive_access_info` se agrega cuando el tema requiere secretos/acceso.

Cada llamada se registra con:

- tool e input;
- contexto Rails resuelto;
- latencia/error;
- resultado completo;
- evidencia normalizada;
- propiedad/cuenta/scope;
- contenido recibido por la AI.

## 11. Flujo interno del AI service

`ai-service/src/server.ts` procesa `/decide` así:

1. Autentica bearer token y asigna correlation ID.
2. Respeta el deadline enviado por Rails.
3. Puede responder saludos/agradecimientos puramente sociales con un clasificador determinístico, sin llamar al modelo.
4. Ejecuta las tools Rails obligatorias.
5. Construye `evidence_catalog`.
6. Llama `generateObject` con Zod y el prompt principal.
7. Aplica el guardrail de emergencias operativas.
8. Ejecuta `GroundedDecisionBuilder`.
9. Si la primera decisión no quedó bien grounded y hay evidencia, puede hacer una segunda llamada con el prompt de revisión.
10. Sanitiza el texto visible al huésped.
11. Devuelve decisión, auditoría, token usage, tool calls, evidencia y fuente final de decisión.

### Contrato público de decisión

```json
{
  "action": "reply | clarify | create_owner_task | create_alert | check_out | no_action",
  "owner_task_kind": "request | inquiry | null",
  "language": "es",
  "message": "texto para el huésped o null",
  "task_summary": "resumen interno o null",
  "title": "máximo 8 palabras o null",
  "owner_task_id": 123,
  "answer_confidence": 0,
  "evidence_ids": [],
  "attachments": [{ "type": "video", "evidence_id": "guide.12" }]
}
```

Nota técnica: `create_alert` existe en el contrato Node. Antes de llegar a Rails se proyecta al contrato interno compatible como una escalación con `alert_type=emergency`; Rails no admite literalmente `create_alert` en su lista histórica de acciones.

### Reglas importantes del prompt/guardrails

- Tool-first: no contestar facts de propiedad o reserva de memoria.
- Resolver antes de escalar: si el huésped dice que algo no funciona, primero usar FAQs, guías, manuales y videos; crear una consulta solamente si no hay instrucciones o si fallaron.
- Responder primero y preguntar solamente si falta un dato material.
- Preservar exactamente URLs, videos, códigos, claves, teléfonos, direcciones, horarios, WiFi, puertas/pisos y secuencias como `#`.
- No mostrar al huésped nombres de tools, evidencias, IDs, fuentes o metadata interna.
- No aprobar excepciones, late checkout, early check-in, refunds o cambios sin una política explícita.
- `check_out` solamente significa que el huésped confirma que ya se fue, no que planea irse.
- `no_action` se usa para agradecimientos/cierres sin una nueva necesidad.
- Emergencias se clasifican por riesgo real, no por la palabra “urgente”. Fuego, humo, gas, inundación grave, intrusión, lesión, riesgo eléctrico, salida insegura o riesgo estructural crean Alert. Una cuna urgente o toallas urgentes siguen siendo Request.

## 12. Qué valida Rails después de la AI

Rails conserva controles técnicos y de seguridad:

- acción permitida y estructura coherente;
- tipo de OwnerTask válido;
- título requerido y máximo 8 palabras;
- respuesta/idioma presentes cuando corresponden;
- attachments válidos;
- no exponer metadata interna ni secretos técnicos;
- autorización para datos sensibles;
- aislamiento real por cuenta y propiedad;
- existencia y alcance de objetos;
- persistencia e idempotencia.

Las referencias semánticas de evidencia no reconocidas son warnings no bloqueantes. Evidencia de otra cuenta/propiedad o acceso sensible no autorizado sí puede bloquear.

Para `create_owner_task`, un `owner_task_id` inexistente, cerrado o fuera del contexto no se modifica: se registra `owner_task_reference_invalid` como warning y se crea un task local nuevo. Un ID válido del mismo tenant, propiedad, huésped, conversación, estado y tipo actualiza el task existente.

## 13. OwnerTasks: pedidos y consultas

`OwnerTask` representa **una necesidad pendiente**, no un mensaje ni un turno.

- `kind=request`: el dueño debe hacer, aprobar, entregar, reparar o coordinar algo.
- `kind=inquiry`: falta una respuesta factual que solamente el dueño puede aportar.
- `status=open|resolved`.
- El título lo genera la AI, es accionable y tiene hasta 8 palabras.
- El contexto completo queda en la conversación; el task no duplica mensajes como evidencia.
- El link visible lleva a esa conversación.

### Crear versus actualizar

Node recibe los tasks abiertos de la conversación. Si el nuevo mensaje agrega detalle a exactamente la misma intención, devuelve ese `owner_task_id`. Si es una intención distinta, devuelve `null`.

Rails:

- actualiza solamente un ID abierto y totalmente compatible;
- crea uno nuevo si no hay ID o la referencia no es válida;
- usa el `source_guest_message_id` y AI trace para evitar duplicados;
- notifica al dueño solamente al crear un OwnerTask nuevo;
- una aclaración que actualiza un task no dispara otra notificación.

La clase pública es `OwnerTask`, pero la tabla y parte del namespace conservan el nombre histórico `guest_requests`/`GuestRequests::Creator`.

## 14. Alertas operativas

Las Alert son independientes de OwnerTask. Se crean para emergencias, mantenimiento grave, quejas u otros incidentes operativos configurados.

- Tienen prioridad, título, descripción, sugerencia al dueño y status.
- Se vinculan a propiedad, huésped, conversación, mensaje original y trace.
- Una emergencia puede además disparar email si la automatización está habilitada.
- Se notifica por el mismo sistema operativo de WhatsApp del dueño.
- La UI y WhatsApp muestran información crítica breve, no una copia completa del chat.

## 15. Checkouts / Salidas

La acción `check_out` crea `CheckoutEvent` solamente cuando el huésped confirma que ya salió.

- Se deduplica por referencia de reserva, fechas o conversación y por MessageSid.
- Estado: pendiente o visto.
- Aparece en la sección “Salidas” y en la categoría `checkouts` del workflow del dueño.
- No es un OwnerTask ni una FAQ aprendible.

## 16. Workflow operativo del dueño por WhatsApp

### Inicio y cola

Al crear un pedido, consulta, alerta o salida, `OwnerEscalationNotifier` calcula pendientes para cada actor autorizado de la propiedad.

- Si no hay sesión activa, crea una sesión `menu` de 30 minutos y envía un único template `owner_escalation_notice` con contadores.
- Si ya existe sesión activa, no manda otro template ni cambia el caso actual; el evento queda en base y será recalculado después.
- Al terminar o expirar la sesión, si quedan pendientes se envía un único aviso actualizado.
- La cola es independiente por actor/número, por lo que dueño y co-host no comparten el mismo cursor de UI.

### Categorías

- Pedidos
- Consultas
- Alertas
- Checkouts

### Estados activos reales

```text
menu
  -> viewing_item
  -> awaiting_reply_text
  -> awaiting_send_confirmation
  -> sending_guest_message
  -> loading_next_case
  -> viewing_item o resolved
```

Para consultas existe un paso adicional:

```text
sending_guest_message
  -> awaiting_learning_confirmation
  -> loading_next_case
```

Estados históricos todavía aceptados por el modelo, pero no parte central del flujo actual: `queued`, `awaiting_ack`, `awaiting_answer`, `on_hold`, `awaiting_owner_reply`, `failed`.

### Contenido mostrado por caso

Pedido/consulta/alerta muestra solamente:

- posición en cola;
- número de caso;
- título;
- propiedad;
- huésped;
- link directo a la conversación;
- un detalle crítico breve solamente para alertas críticas.

Checkout muestra posición, propiedad, huésped, estado y link.

### Comandos y envío

Acciones principales: `Responder`, `Siguiente`, `Omitir`, `Salir`; checkout usa `Marcar como visto`.

Al responder:

1. El dueño escribe el texto exacto.
2. Ayla muestra una única lista interactiva con `Enviar`, `Traducir al idioma del huésped`, `Editar` y `Cancelar`.
3. Traducir crea/actualiza un `OwnerReplyDraft` y vuelve a pedir confirmación.
4. Enviar hace claim atómico del caso, manda al huésped, marca delivery/estado y limpia el contexto activo.
5. El siguiente pendiente se consulta nuevamente en la base; no se reutiliza una lista cacheada.

Cuando una consulta fue respondida, Ayla pregunta si se desea recordar esa respuesta. `Sí, recordar` crea una FAQ aprobada para esa propiedad; `No recordar` continúa sin aprender.

## 17. Observer mode

Observer es actualmente un **listener de actividad y un aviso**, no un segundo workflow.

```text
Message/Conversation cambia
  -> Observer::ActivityRecorder
  -> ConversationObserverActivity
  -> job diferido 5 minutos
  -> agrupa actividad pendiente del actor
  -> WhatsApp con link al panel
  -> fin
```

Reglas:

- Ventana de agrupación: 5 minutos desde la actividad más reciente.
- Varios mensajes de la misma conversación generan un aviso.
- Varias conversaciones generan un aviso agregado y link al listado con filtro unread.
- Si existe una sesión operativa activa o una notificación operativa muy reciente, Observer espera; lo operativo tiene prioridad.
- No crea `ObserverWhatsappSession`.
- No consume mensajes entrantes.
- No tiene comandos, navegación, siguiente/anterior ni estado de WhatsApp.
- Abrir la conversación en el panel marca su actividad Observer como vista.

El envío usa `TWILIO_OWNER_OBSERVER_NOTICE_CONTENT_SID` si está configurado; si no, intenta mensaje libre. El template usa exactamente dos variables: resumen y URL.

## 18. Traducciones

Hay dos flujos separados.

### Traducir una conversación en el panel

- El original nunca se modifica.
- El dueño elige traducir la página actual.
- El idioma destino es el locale global `ES/EN` de la interfaz.
- Se persiste un `MessageTranslation` por mensaje e idioma.
- Se cargan 20 mensajes por página; no se manda automáticamente toda una conversación infinita.
- El servicio agrupa hasta 50 mensajes o 30.000 caracteres por request al provider.
- Traducciones ya existentes se reutilizan.
- `IntegrityChecker` impide aceptar una traducción que cambie URLs, códigos u otros valores protegidos.

### Traducir una respuesta del dueño

- El dueño escribe en el idioma de su interfaz/actor.
- El destino es `guest.language`, detectado por la decisión AI y persistido en el huésped.
- Se crea `OwnerReplyDraft`.
- El dueño confirma si envía original o traducción; ninguna traducción se envía automáticamente.

### Providers

- `TRANSLATION_PROVIDER=deepl`: DeepL es el provider activo.
- `TRANSLATION_PROVIDER=ai_service`: usa `/translate/messages` en Node.
- DeepL Free: `DEEPL_API_BASE_URL=https://api-free.deepl.com`.
- DeepL Pro: `DEEPL_API_BASE_URL=https://api.deepl.com`.
- El fallback entre providers solamente ocurre si se inyecta/configura explícitamente un fallback en `Translation::Service`; no se debe asumir fallback automático global.

## 19. Twilio y templates

`Whatsapp::ProviderFactory` selecciona `twilio` o `null` mediante `WHATSAPP_PROVIDER`.

`TwilioProvider` soporta:

- mensaje libre;
- media;
- Content SID/template con variables;
- contenidos interactivos creados/registrados por `TwilioContentRegistry`;
- status callback a `/webhooks/whatsapp_status`;
- captura de SID, status y error sanitizado.

Templates iniciados por negocio son necesarios fuera de la ventana de atención de WhatsApp. Los mensajes libres/interactivos dentro de una conversación abierta siguen las reglas de Twilio/Meta.

Variables críticas:

- `TWILIO_ACCOUNT_SID`
- `TWILIO_AUTH_TOKEN`
- `TWILIO_WHATSAPP_FROM`
- `TWILIO_OWNER_ESCALATION_NOTICE_CONTENT_SID`
- `TWILIO_OWNER_OBSERVER_NOTICE_CONTENT_SID`
- `APP_HOST`

El registro valida que las keys de variables enviadas coincidan con la definición conocida antes de llamar Twilio.

## 20. Fallbacks técnicos

No se cambia la lógica de negocio cuando ocurre un fallback; se centraliza el texto y el diagnóstico.

Mensaje por defecto:

```text
Estoy teniendo un inconveniente técnico temporal y no pude responder tu consulta. Si es urgente, podés comunicarte con el anfitrión al {{owner_phone}}.
```

Se configura con `AI_TECHNICAL_FALLBACK_MESSAGE`. Si no hay teléfono, se elimina la oración que lo contiene.

Categorías:

- `AI_TIMEOUT`
- `OPENAI_TIMEOUT`
- `TOOL_TIMEOUT`
- `HTTP_TIMEOUT`
- `NETWORK_ERROR`
- `OPENAI_ERROR`
- `TOOL_ERROR`
- `INTERNAL_EXCEPTION`
- `UNKNOWN`

AI Trace conserva la excepción original, pero presenta descripción humana, duración, provider, correlation ID, tools y mensaje finalmente enviado. No se expone stack trace ni infraestructura al huésped.

### Presupuesto Rails -> AI

Valores por defecto actuales:

- connect timeout: 3 s;
- read timeout: 48 s;
- deadline total Rails: 50 s;
- deadline comunicado a Node: 45 s;
- máximo 2 intentos.

Los read timeouts largos no son retryables. Se reintentan solamente errores de conexión rápidos y HTTP 502/503, respetando el deadline compartido.

## 21. Observabilidad

### AI Trace (`AIDecisionLog`)

Permite ver:

- conversación, propiedad, cuenta, huésped y mensaje;
- payload Rails -> Node;
- decisión original y respuesta final Rails;
- tools solicitadas y respuestas completas;
- contexto resuelto para cada tool;
- evidencia retornada y evidencia referenciada;
- contenido de evidencia;
- validaciones, warnings y rechazos;
- grounded decision, reintento, fallback;
- intentos Rails -> Node;
- envío/estado de WhatsApp.

El modelo sanitiza secretos y contenido sensible antes de exponer JSON en el panel.

### OperationalError

`ErrorReporter` manda el evento a Sentry y también crea un registro administrable en PostgreSQL. Filtra claves como password, token, authorization, signature, API key y secret.

### Sentry

Rails y Node deben usar proyectos Sentry separados, cada uno con su DSN. Ambos aceptan:

- `SENTRY_DSN`
- `SENTRY_ENVIRONMENT`
- `SENTRY_RELEASE`
- `SENTRY_TRACES_SAMPLE_RATE`
- `SENTRY_PROFILES_SAMPLE_RATE`

Rails tiene además métricas por request: duración, allocations, RSS, bytes, SQL y registros instanciados.

## 22. Idempotencia y concurrencia

Puntos deliberados:

- `MessageSid` evita duplicar mensajes entrantes.
- La sesión del dueño guarda los últimos 100 MessageSids procesados.
- OwnerTask guarda `source_guest_message_id` y AI trace para no duplicar efectos.
- Checkout usa claves únicas por reserva/mensaje/SID.
- El claim de una respuesta del dueño distingue `pending`, `sending`, `responded` y `failed` para evitar doble envío entre dueño y co-host.
- Las transiciones críticas usan locks de Account, Conversation, Session, Task o Activity según el flujo.
- Después de resolver un caso, la sesión limpia item y draft y consulta pendientes nuevamente desde la base.

## 23. Panel web

Secciones principales:

- Panel
- Propiedades
- Conversaciones
- Pedidos
- Consultas
- Alertas
- Salidas
- Configuración: perfil, AI y WhatsApp
- Suscripción/facturación

Secciones admin:

- Usuarios y límites
- Estadísticas
- Errores
- IA Config
- AI Trace

Las cards de propiedades son deliberadamente compactas: nombre/dirección, tags, co-host y acciones abrir/copiar link/copiar o descargar QR. El show de propiedad expone toda la información que el dueño/administrador autorizado puede editar, incluidos los datos sensibles para ese actor del panel.

## 24. Variables de entorno esenciales

### Rails

```text
RAILS_ENV
RAILS_MASTER_KEY
SECRET_KEY_BASE
DATABASE_URL
APP_HOST

WHATSAPP_PROVIDER
TWILIO_ACCOUNT_SID
TWILIO_AUTH_TOKEN
TWILIO_WHATSAPP_FROM
TWILIO_OWNER_ESCALATION_NOTICE_CONTENT_SID
TWILIO_OWNER_OBSERVER_NOTICE_CONTENT_SID

AI_SERVICE_URL
AI_SERVICE_TOKEN
AI_TOOLS_BASE_URL
AI_CONNECT_TIMEOUT_SECONDS
AI_RESPONSE_TIMEOUT_SECONDS
AI_TOTAL_DEADLINE_SECONDS
AI_SERVICE_DEADLINE_SECONDS
AI_TECHNICAL_FALLBACK_MESSAGE

TRANSLATION_PROVIDER
DEEPL_API_KEY
DEEPL_API_BASE_URL
DEEPL_OPEN_TIMEOUT_SECONDS
DEEPL_READ_TIMEOUT_SECONDS

STRIPE_SECRET_KEY
STRIPE_WEBHOOK_SECRET
STRIPE_PRICE_*
RESEND_API_KEY
RESEND_FROM_EMAIL
SENTRY_*
```

### Node AI service

```text
AI_SERVICE_TOKEN
RAILS_TOOLS_BASE_URL
AI_GATEWAY_API_KEY
AI_MODEL
SENTRY_*
```

No envolver los valores de ENV en comillas en Render salvo que las comillas formen parte real del valor. El token compartido debe ser idéntico byte por byte.

## 25. Tests y cómo verificar cambios

Rails usa Minitest. Áreas especialmente cubiertas:

- routing e idempotencia WhatsApp;
- parser y firma Twilio;
- cola/sesión/estado del dueño;
- concurrencia dueño/co-host;
- Observer sin sesiones;
- creación/actualización de OwnerTasks;
- AI contract, validator, trace y fallback;
- DeepL, batching, integridad y drafts;
- permisos admin/cuenta;
- límites, billing y Stripe.

Node usa tests TypeScript para:

- schema de decisión;
- prompt;
- evidencia y grounded builder;
- tools Rails;
- emergencias;
- sanitización;
- fallback técnico;
- Sentry;
- importación y traducción.

Comandos orientativos:

```bash
bin/rails test
cd ai-service && npm test
```

El entorno local de esta máquina tiene Ruby 3.0.3 y Node 16.18; el AI service exige Node 20.6+, por lo que sus tests deben ejecutarse con el runtime correcto.

## 26. Archivos que otra AI debe leer primero

En este orden:

1. `docs/AI_ARCHITECTURE_PRINCIPLES.md`
2. `config/routes.rb`
3. `app/services/whatsapp/incoming_message_handler.rb`
4. `app/services/ai/context_builder.rb`
5. `app/services/ai/decision_service.rb`
6. `app/services/ai/decision_validator.rb`
7. `app/services/ai/source_registry.rb`
8. `app/controllers/internal/ai/tools_controller.rb`
9. `ai-service/src/server.ts`
10. `ai-service/src/decision-schema.ts`
11. `ai-service/src/decision-system-prompt.ts`
12. `ai-service/src/grounded-decision-builder.ts`
13. `app/services/guest_requests/creator.rb`
14. `app/services/alerts/creator.rb`
15. `app/services/whatsapp/owner_inbound_message_handler.rb`
16. `app/services/whatsapp/owner_escalation_notifier.rb`
17. `app/services/observer/activity_recorder.rb`
18. `app/services/whatsapp/observer_notifier.rb`
19. `app/controllers/conversations_controller.rb`
20. `app/services/translation/*`

## 27. Invariantes que no deben romperse

1. Nunca mezclar datos de cuentas o propiedades.
2. El contexto de una tool lo resuelve Rails mediante un token firmado; no confiar en IDs libres del request.
3. Node no persiste dominio ni envía WhatsApp.
4. Rails no debe reemplazar una decisión válida por juzgar semánticamente una evidencia desconocida; puede advertir.
5. Datos sensibles requieren autorización de reserva.
6. Un número de dueño/co-host siempre entra al flujo de host antes que al de huésped.
7. Observer nunca consume inbound ni crea sesiones.
8. Una sesión operativa activa no cambia de caso por eventos nuevos.
9. Un OwnerTask representa una intención pendiente, no cada mensaje.
10. Actualizar un OwnerTask no vuelve a notificar; crear uno sí.
11. Resolver/enviar limpia el caso activo y recalcula pendientes desde PostgreSQL.
12. Traducciones nunca reemplazan originales y requieren confirmación antes de enviar una respuesta del dueño.
13. URLs, códigos, horarios y pasos críticos se conservan exactamente.
14. Los efectos deben ser idempotentes frente a retries/webhooks duplicados.
15. Los errores visibles no deben filtrar secretos.

## 28. Caveats y deuda técnica conocida

- `OwnerTask` todavía usa la tabla y nombres históricos `guest_requests`; no interpretar que sigue siendo “un mensaje”.
- `Conversation` única por teléfono puede relinkearse entre propiedades/cuentas; por eso los snapshots de `Message` y los scopes de lectura son críticos.
- El modelo Rails contiene estados históricos de sesión que ya no son parte del camino principal.
- El contrato Node conoce `create_alert`, pero lo adapta a la representación histórica de escalación antes de Rails.
- Existe todavía preferencia de idioma en User/CoHost para ciertos flujos WhatsApp; en el panel de conversaciones el idioma objetivo es el locale global ES/EN.
- README y documentación vieja pueden mencionar planes o validaciones semánticas anteriores; ante conflicto, prevalece el código y este snapshot.
- `APP_HOST` se usa para links al panel; debe ser el origen completo correcto de producción.

## 29. Resumen de una frase

Ayla es una aplicación Rails multi-tenant que mantiene la autoridad, seguridad, persistencia y comunicaciones, complementada por un servicio Node tool-first que interpreta mensajes de huéspedes, consulta exclusivamente conocimiento autorizado de la propiedad, produce decisiones estructuradas y deja cada decisión totalmente auditable.
