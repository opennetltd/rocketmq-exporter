# Architecture — rocketmq-exporter

## Overview

A Spring Boot service that bridges Apache RocketMQ cluster metrics into Prometheus and OpenTelemetry
(OTLP). It uses the RocketMQ admin API (`MQAdminExt`) to poll brokers on a cron schedule, stores
results in in-memory Guava caches, and serves them as Prometheus text on `GET /metrics`. A second
gRPC server (port 5559) accepts OTLP metric pushes from an OpenTelemetry collector and feeds them
into the same collector, enabling RocketMQ monitoring via SkyWalking or any OTLP-compatible backend.

## Component Map

```
RocketMQ cluster (NameServer + Brokers)
        │  rocketmq-tools admin API (TCP)
        ▼
MetricsCollectTask  (@Scheduled, 6 tasks × every 1 min at :15s)
        │  writes
        ▼
RMQMetricsCollector  (Prometheus Collector subclass)
  ├── Guava Cache<MetricKey, Double|Long|Int>  (TTL = outOfTimeSeconds, default 60 s)
  └── collect()  → List<MetricFamilySamples>
        │
        ├── HTTP GET /metrics  ──►  Prometheus / Grafana
        │   RMQMetricsController → RMQMetricsServiceImpl.metrics()
        │
        └── gRPC port 5559 (OTLP)  ──►  SkyWalking / OTel backend
            OtlpGrpcLauncher → OtlpMetricsCollectorService
```

## Directory Structure

```
src/main/java/…/exporter/
├── RocketMQExporterApplication.java   # Spring Boot entry point
├── collector/
│   └── RMQMetricsCollector.java       # Prometheus Collector; all metric caches live here
├── config/
│   ├── RMQConfigure.java              # @ConfigurationProperties for rocketmq.config.*
│   ├── ScheduleConfig.java            # enables @Scheduled
│   └── CollectClientMetricExecutorConfig.java  # thread-pool config for client-metric tasks
├── controller/
│   └── RMQMetricsController.java      # single @RequestMapping for /metrics endpoint
├── model/
│   ├── BrokerRuntimeStats.java        # parses KVTable from broker runtime stats
│   └── metrics/                       # POJO metric keys (used as Guava cache keys)
├── otlp/
│   ├── OtlpGrpcLauncher.java          # starts gRPC server on grpc.server.port
│   └── OtlpMetricsCollectorService.java  # gRPC service impl; writes into collector
├── service/
│   ├── RMQMetricsService.java         # interface: getCollector() + metrics(Writer)
│   ├── impl/RMQMetricsServiceImpl.java
│   └── client/
│       ├── MQAdminExtImpl.java        # extends DefaultMQAdminExt; adds queryMsgByOffset
│       └── MQAdminInstance.java       # Spring bean wrapping MQAdminExtImpl
└── task/
    ├── MetricsCollectTask.java        # 6 @Scheduled methods + client-metric thread pool
    ├── ClientMetricTaskRunnable.java  # per-consumer-group runnable (pulls client-side stats)
    └── ClientMetricCollectorFixedThreadPoolExecutor.java
```

## Key Concepts

| Concept | Explanation |
|---------|-------------|
| **MetricsCollectTask** | Spring `@Component` with six `@Scheduled` cron methods: `collectTopicOffset`, `collectProducer`, `collectConsumerOffset`, `collectBrokerStatsTopic`, `collectBrokerStats`, `collectBrokerRuntimeStats`. All default to `15 0/1 * * * ?` (15 seconds past every minute). Each method calls `metricsService.getCollector().add*Metric(...)` to upsert into the cache. |
| **RMQMetricsCollector** | Extends `io.prometheus.client.Collector`. Holds ~15 typed Guava caches (one per metric family). On `collect()`, iterates each cache and converts to `GaugeMetricFamily` samples. Entries expire after `outOfTimeSeconds` if not refreshed. |
| **Metric cache keys** | POJOs in `model/metrics/` (e.g. `BrokerMetric`, `ConsumerMetric`) — the cache key uniquely identifies a label combination. Guava cache uses their `equals`/`hashCode`. |
| **Client-metric thread pool** | Consumer per-client stats (fail TPS, ok TPS, RT, pull RT/TPS) are expensive per connection; collected in a fixed thread pool (default 10 threads, queue 5000). Configured via `threadpool.collect-client-metric-executor.*`. |
| **OTLP ingest** | `OtlpGrpcLauncher` starts a gRPC server (`io.grpc.ServerBuilder`) using the OpenTelemetry proto service. `OtlpMetricsCollectorService` writes received OTLP metrics into `RMQMetricsCollector`. |

## Data / Request Flow

```
1. Spring startup → MQAdminInstance.start() connects to namesrvAddr
2. MetricsCollectTask.init() fetches cluster topology and logs broker info
3. Every ~1 min: each @Scheduled method calls mqAdminExt.*() to query RocketMQ
4. Results written into Guava caches in RMQMetricsCollector via add*Metric() calls
5. Prometheus scrapes GET /metrics → RMQMetricsController → RMQMetricsServiceImpl.metrics()
   → RMQMetricsCollector.collect() iterates caches → writes Prometheus text format to response
6. OTLP path (parallel): OTel collector pushes metrics via gRPC to port 5559
   → OtlpMetricsCollectorService feeds them into the same RMQMetricsCollector caches
```

## Integration Points

| System | How this repo interacts with it |
|--------|---------------------------------|
| RocketMQ NameServer | Admin TCP connection on startup + every scheduled task; reads cluster/topic/consumer stats |
| Prometheus | Scraped via HTTP `GET /metrics` (port 5557, text/plain 0.0.4) |
| Grafana | Two dashboard JSONs bundled (`rocketmq_exporter.json`, `rocketmq_exporter_overview.json`); Grafana Dashboard ID 10477 |
| SkyWalking / OTel backend | OTLP gRPC push accepted on port 5559 |
| AWS ECR | Docker image pushed to `942878658013.dkr.ecr.eu-central-1.amazonaws.com/devops/rocketmq-exporter` on every git tag |

## Constraints & Invariants

- Collection tasks are guarded by `rmqConfigure.isEnableCollect()` — set `rocketmq.config.enableCollect=false` to disable all polling without stopping the process.
- Guava cache TTL (`outOfTimeSeconds`) is the staleness window: a metric disappears from `/metrics` output if no collection task refreshes it within that window.
- The `@Scheduled` cron expressions are all configurable in `application.yml`; default aligns all tasks at :15 past every minute to avoid thundering-herd on the broker.
- `RMQMetricsServiceImpl` deliberately does NOT emit Prometheus `# HELP` / `# TYPE` lines (the `writeEscapedHelp` override skips them) — consuming systems must not rely on type hints.
- CI workflow uses JDK 8 for Maven build but `Dockerfile` uses JDK 21 (temurin:21-jre); the runtime image is JDK 21 regardless.
