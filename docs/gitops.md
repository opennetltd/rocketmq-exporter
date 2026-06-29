# GitOps & Deployment — rocketmq-exporter

## Deployment Path

This repo does **not** use ArgoCD or a yaml-repo. The release path is:
push a git tag → GitHub Actions (`.github/workflows/build.yml`) runs `mvn clean package`, then builds
and pushes a Docker image to AWS ECR at
`942878658013.dkr.ecr.eu-central-1.amazonaws.com/devops/rocketmq-exporter:<tag>` (and also `:latest`).
Deployment of the image to Kubernetes/ECS is managed separately (not in this repo).

## How to Release a New Version

```bash
git tag v0.0.3          # or whatever semver
git push origin v0.0.3  # triggers build.yml → ECR push
```

The workflow uses `aws-actions/configure-aws-credentials` with `AWS_ACCESS_KEY_ID` /
`AWS_SECRET_ACCESS_KEY` secrets stored in the GitHub repo — target region `eu-central-1`.

## Local Docker Build

```bash
# Uses the top-level Dockerfile (multi-stage: maven:3.9-eclipse-temurin-21 build + eclipse-temurin:21-jre runtime)
docker build --platform linux/amd64 -t pagi.io/rocketmq-exporter-jdk21 .
# or via build.sh (same command):
bash build.sh
```

Note: `.github/workflows/build.yml` uses `src/main/docker/Dockerfile` (older single-stage), while
`build.sh` and the top-level `Dockerfile` use the newer multi-stage JDK 21 image. New builds should
use the top-level `Dockerfile`.

## Branch Strategy

| Branch | Purpose | Merge target |
|--------|---------|--------------|
| `master` | production-ready | — |
| feature / fix branch | per-ticket work | `master` via PR |

## CI

Trigger: **push of any tag** (not push to branch — branch pushes do not build).

Steps:
1. `mvn clean package -Dmaven.test.skip=true` (JDK 8 in CI)
2. AWS ECR login
3. `docker/build-push-action` using `src/main/docker/Dockerfile`
4. Additional `docker push` for `:latest` tag

## Checkstyle / Linting

Checkstyle runs as part of the `verify` phase (not `package`):

```bash
mvn verify          # runs checkstyle + tests
mvn checkstyle:check  # checkstyle only
```

Config: `style/rmq_checkstyle.xml`. The CI workflow skips tests (`-Dmaven.test.skip=true`) so
checkstyle is **not** enforced in CI — run `mvn verify` locally before opening a PR.

## Secrets

No SOPS or external secret management in this repo. The exporter's own ACL credentials
(`rocketmq.config.accessKey` / `secretKey`) are injected at runtime via environment variables or
mounted config — not stored in this repo.
