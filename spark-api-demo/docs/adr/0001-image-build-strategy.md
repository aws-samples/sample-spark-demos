# ADR 0001 — Image Build Strategy for SPARK API (Spike Result)

Date: 2026-08-18 · Status: accepted

## Context

SPARK API does not publish container images. The upstream Dockerfiles
(`02-backend/*/Dockerfile`) are tailored to an internal build environment:

1. `FROM <CONTAINER_REGISTRY>/...` placeholders — including for base images.
2. `--mount=type=bind,source=uv.lock` — but **not a single `uv.lock` is
   included in the repo** (verified: `find 02-backend -name uv.lock` → empty).
3. `[tool.uv.sources]` references `../../03-shared-services/*` by path,
   which lies outside the Docker build context (service directory);
   alternatively, a `UV_INDEX_*` mechanism exists for a private index.

## Spike (local, norm-matching as reference service)

- **Variant B (synthetic build context):** Copy the service directory +
  `03-shared-services/` into a CI workspace, generate `uv lock`.
  → Path dependencies resolve cleanly.
- **Finding, version conflict:** `uv lock` initially fails — upstream conflict
  `norm-matching: mistralai>=1.12.4,<1.13` vs. `bmds-ki-validierung: mistralai>=2.0`.
  The conflict lies exclusively in the `dev` dependency group (test tooling).
  → **Workaround:** strip `[dependency-groups] dev` in the CI workspace
  (the runtime image installs with `--no-dev` anyway). The lock then resolves
  in <2 s (181 packages).
- **Vendor layout:** Copy shared libs to `_vendor/03-shared-services/` +
  path rewrite in `pyproject.toml` → the build context remains the
  service directory, upstream `COPY . /app` works unchanged.

## Decision

**Variant B (vendor context), no CodeArtefact/UV_INDEX.**

CodeBuild performs a deterministic CI workspace transformation per service
(the upstream repo remains unchanged; all steps are versioned in the script
`pipeline/prepare-context.sh`):

1. Stage the service directory as the build context.
2. Copy `03-shared-services/` to `_vendor/`; rewrite `[tool.uv.sources]`
   paths to `_vendor/...`.
3. Remove `[dependency-groups] dev` (test tooling only; fixes the
   mistralai conflict), the `test-deps` stage in the Dockerfile is dropped.
4. Generate `uv lock` in the workspace (the missing lockfile).
5. Replace base image placeholders according to `pipeline/base-image-map.env`
   (`astral-uv-python-3.12-bookworm` → `ghcr.io/astral-sh/uv:python3.12-bookworm`,
   `python-3.12-bookworm` → `public.ecr.aws/docker/library/python:3.12-bookworm`,
   `node:20-bookworm` → `public.ecr.aws/docker/library/node:20-bookworm`).
6. `docker build` (amd64) → push to ECR, tag = upstream Git SHA.

## Consequences

- No private package index needed; one build script covers all Python services.
- The dev-group strip means: upstream tests do not run in the image build
  (deliberate; the demo builds runtime images). An upstream issue about the
  missing uv.locks and the mistralai conflict is to be filed.
- Individual services that cannot be built are disabled via umbrella flag and
  documented (Requirement 3.3).
- Final verification of the Docker build happens in CodeBuild (amd64-native);
  dependency resolution was verified locally (arm64 host).
