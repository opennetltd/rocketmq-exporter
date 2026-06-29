# Runbook — rocketmq-exporter

## Common Operations

### Run the exporter locally against a RocketMQ cluster

```bash
# Point it at your NameServer, then start
java -jar target/rocketmq-exporter-0.0.3-SNAPSHOT-exec.jar \
  --rocketmq.config.namesrvAddr=<namesrv-host>:9876

# Verify metrics are served
curl http://localhost:5557/metrics | head -40
```

### Build and run via Docker

```bash
docker build --platform linux/amd64 -t rocketmq-exporter .
docker run -d --rm \
  -p 5557:5557 -p 5559:5559 \
  -e rocketmq.config.namesrvAddr=<namesrv-host>:9876 \
  rocketmq-exporter
```

### Run tests

```bash
mvn test                        # all tests
mvn test -Dtest=UtilsTest       # single test class
```

### Check checkstyle locally

```bash
mvn checkstyle:check
# Config: style/rmq_checkstyle.xml
```

---

## Known Quirks & Gotchas

- **CI builds with JDK 8 but runs on JDK 21** — `build.yml` sets `java-version: '8'` for Maven yet
  the runtime Dockerfile uses `eclipse-temurin:21-jre`. Keep source/target at 21 in `pom.xml`
  (currently `<maven.compiler.source>21</maven.compiler.source>`). This may cause CI failures if the
  JDK 8 compiler rejects JDK 21 syntax — confirm before bumping language features.
- **Two Dockerfiles** — top-level `Dockerfile` (multi-stage, JDK 21, used by `build.sh`) vs
  `src/main/docker/Dockerfile` (used by CI workflow and the legacy `docker-maven-plugin`).
  Keep them in sync, or standardise on one.
- **Checkstyle not enforced in CI** — the workflow uses `-Dmaven.test.skip=true` and only runs the
  `package` phase, which does not trigger the `verify`-phase checkstyle execution. Run `mvn verify`
  locally.
- **`spring.main.allow-circular-references: true`** is set in `application.yml` — this is a Spring
  Boot 2.6+ workaround for a circular dependency in the codebase. Do not remove without auditing.
- **Metrics disappear after `outOfTimeSeconds`** — if the NameServer is unreachable and collection
  tasks start failing, cached metrics will expire (default 60 s) and `/metrics` output will go empty.
  This is intentional: stale metrics are worse than no metrics for alerting.
- **`RMQMetricsServiceImpl.writeEscapedHelp` omits `# HELP` / `# TYPE` lines** — the output is
  valid Prometheus text but lacks type hints. Grafana and Prometheus will still scrape it correctly.

---

## Troubleshooting

### Exporter starts but `/metrics` returns empty output

**Cause**: `rocketmq.config.enableCollect=false`, or the NameServer is unreachable and all cache
entries have expired.

**Fix**:
1. Check `enableCollect` in `application.yml` — must be `true`.
2. Check logs for `collectTopicOffset-exception` / `collectBrokerStats-get cluster info … error`.
3. Verify NameServer reachability: `telnet <namesrv-host> 9876`.

### Startup fails with connection refused

**Cause**: `MetricsCollectTask.init()` calls `mqAdminExt.examineBrokerClusterInfo()` at startup; if
the NameServer is down, the app will throw and may not start cleanly.

**Fix**: Ensure NameServer is up before starting the exporter, or wrap the call in a retry loop
(not currently implemented upstream).

### High memory usage / thread pool queue full

**Cause**: `ClientMetricTaskRunnable` tasks are queuing up faster than the 10-thread pool can drain
them. Visible in logs as `DiscardOldestPolicy` warnings.

**Fix**: Increase `threadpool.collect-client-metric-executor.core-pool-size` / `maximum-pool-size`
in `application.yml`. Check if there is an unusually large number of consumer groups.

### `TOPIC_NOT_EXIST` / `CONSUMER_NOT_ONLINE` log spam

These are expected and intentionally suppressed (response codes `TOPIC_NOT_EXIST` and
`CONSUMER_NOT_ONLINE` are silently skipped). Safe to ignore.

---

## Prometheus / Grafana

- Grafana Dashboard IDs: **10477** (RocketMQ Exporter Overview) and the bundled
  `rocketmq_exporter.json` / `rocketmq_exporter_overview.json`.
- The second dashboard requires two extra Prometheus labels (`Env`, `Cluster`) configured in the
  scrape job:
  ```yaml
  - job_name: 'rocketmq-exporter'
    static_configs:
      - targets: ['<exporter-host>:5557']
        labels:
          Env: 'prod'
          Cluster: 'MQCluster'
  ```

---

## Incident Checklist

1. Is `/metrics` returning data? (`curl http://<host>:5557/metrics | wc -l`)
2. Are collection tasks running? (check logs for `collection task starting` / `finished` lines)
3. Is the NameServer reachable from the exporter pod/host?
4. Has the RocketMQ broker version changed? Ensure `rocketmq.config.rocketmqVersion` matches.
5. Escalate to the platform/SRE team if broker API errors persist.
