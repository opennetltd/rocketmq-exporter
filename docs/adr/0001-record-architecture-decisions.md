# Design Decisions — rocketmq-exporter

<!--
ADR format: one section per decision.
Lead with the decision itself, then context, then consequences.
Keep old decisions even when superseded — mark them [SUPERSEDED by #N].
-->

## ADR-001: Use Guava in-memory cache with TTL instead of direct Prometheus Gauge

**Status**: Accepted

**Decision**: Metrics collected from RocketMQ are stored in Guava `Cache<MetricKey, Double|Long>` objects
inside `RMQMetricsCollector`, with a configurable TTL (`outOfTimeSeconds`, default 60 s). The Prometheus
`collect()` method reads these caches on each scrape.

**Context**: RocketMQ admin API calls are slow and fan out to multiple brokers. Holding metric values
in-process caches decouples the scrape latency from broker poll latency, and naturally drops stale
entries when a topic/consumer disappears (cache expiry rather than explicit deletion).

**Consequences**:
- Metrics are at most `outOfTimeSeconds` stale relative to broker reality.
- If collection tasks fail continuously, all metrics will disappear from `/metrics` after TTL — this
  is intentional (silent stale data is worse than absent data for alerting).

---

## ADR-002: OTLP gRPC ingest on port 5559

**Status**: Accepted

**Decision**: A second server (gRPC on port 5559) accepts OpenTelemetry Protocol metrics pushes,
in addition to the pull-based Prometheus scrape on port 5557.

**Context**: SkyWalking 10.0+ integrates RocketMQ monitoring via OTLP + OTel collector, requiring a
push endpoint. Adding gRPC ingest to the same process reuses the existing metric cache and avoids
running a separate sidecar.

**Consequences**:
- Two ports must be exposed in any Kubernetes Service / Docker run command.
- The `allow-circular-references: true` workaround in `application.yml` exists because of a Spring Boot
  circular dependency introduced by the OTLP service wiring — do not remove without auditing.

---

<!--
Tips for what belongs here vs other files:

  decisions.md  <- WHY something is designed this way (non-obvious choices,
                   past incidents, external constraints, rejected alternatives)
  architecture.md <- WHAT the system looks like
  runbook.md    <- HOW to operate it

  If a future engineer would ask "why on earth does it work this way?" ->
  that answer belongs in decisions.md.
-->
