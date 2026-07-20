# Render: configuración de memoria

El web service Rails de 512 MB debe ejecutar un único worker Puma con un máximo
de cinco threads.

Variables del web service:

```text
WEB_CONCURRENCY=1
RAILS_MAX_THREADS=5
```

`config/puma.rb` respeta ambas variables. Con `WEB_CONCURRENCY=1`, Puma inicia
un único worker con `Min threads: 5` y `Max threads: 5`. No se debe aumentar
`WEB_CONCURRENCY` en una instancia de 512 MB.

Variables de observabilidad recomendadas:

```text
SENTRY_DSN=<DSN del proyecto Rails>
SENTRY_ENVIRONMENT=production
SENTRY_RELEASE=<identificador del deploy>
SENTRY_TRACES_SAMPLE_RATE=0.1
SENTRY_PROFILES_SAMPLE_RATE=0.05
```

El `ai-service` utiliza las mismas variables, con el DSN de su propio proyecto
Sentry. Debe ejecutarse con Node 20.6 o posterior; el comando `npm start`
precarga la instrumentación ESM antes de cargar el servidor.

Alertas recomendadas:

- reinicio o evento de memoria de Render;
- aumento del error rate;
- p95 superior a 2 segundos;
- aumento de errores del AI service;
- fallos de Twilio;
- requests Rails superiores a 2 segundos.

El endpoint `/up` conserva únicamente el health check estándar y no expone
configuración ni información sensible.
