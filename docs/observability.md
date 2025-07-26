# Observability

## Logging

- JSON logs with correlation IDs via middleware.
- Standard fields: timestamp, level, logger, message, request_id (when available).

## Metrics & Tracing

- (Roadmap) Expose Prometheus metrics: ingest latency, search latency, install success rate.
- (Roadmap) OpenTelemetry tracing around install steps and gateway calls.

## Audit

- Record ingestion attempts and install steps in application logs.
- Consider forwarding logs to ELK/Loki for retention and analysis.
