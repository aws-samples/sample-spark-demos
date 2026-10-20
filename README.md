# SPARK on AWS — Demo Deployments

Automated demo deployments of the openCode projects [SPARK Workflow](https://gitlab.opencode.de/bmds/planungs-und-genehmigungsbeschleunigung/spark-workflow) and [SPARK API](https://gitlab.opencode.de/bmds/planungs-und-genehmigungsbeschleunigung/spark-api) on Amazon EKS.

> **This is sample code, for non-production usage.** You should work with
> your security and legal teams to meet your organizational security,
> regulatory and compliance requirements before deployment. The
> [threat model](docs/THREAT-MODEL.md) lists the demo-only risks these
> deployments accept and the hardening required before any production use.

> **These demos cost money while they run — roughly EUR 60–70 per day for
> spark-workflow-demo and a similar amount for spark-api-demo (EKS nodes,
> RDS, NAT gateway, load balancer; spark-api-demo adds CodeBuild minutes per
> image build).** Tear a demo down when you are done:
>
> ```bash
> make -C spark-workflow-demo destroy
> make -C spark-api-demo destroy
> ```
>
> Both destroys are hands-off and remove everything the demo created,
> including data. Set `DEMO_ALLOWED_CIDRS` in `.env` unless the demo may be
> reachable from the whole internet.

**Vision:** Open-source solutions for the public sector, operated on AWS — the application core remains fully open source, AWS provides the managed infrastructure (EKS, RDS PostgreSQL, S3, ElastiCache) where it is sensible and cleanly integrable.

## Repository Structure

```
.
├── spark-workflow-demo/       # Demo deployment for SPARK Workflow
│   ├── spark-workflow/        # Upstream code (git submodule, EUPL-1.2)
│   ├── terraform/             # Infrastructure (VPC, EKS, RDS, S3, ...)
│   ├── helm/                  # Demo overrides & platform charts
│   └── README.md
├── spark-api-demo/            # Demo deployment for SPARK API
│   ├── spark-api/             # Upstream code (git submodule, EUPL-1.2)
│   ├── terraform/             # Infrastructure incl. ECR + CodeBuild
│   ├── helm/                  # Demo umbrella & overrides
│   └── README.md
```

## Core Principles

1. **Open-source core:** All application and platform components (Keycloak, Temporal, Qdrant, LiteLLM, Envoy Gateway, ...) are open source. AWS-native services are used only as the infrastructure foundation (EKS, RDS for PostgreSQL, S3, ElastiCache for Valkey, ECR, Secrets Manager).
2. **Terraform only** for infrastructure, **Helm** for the workloads.
3. **Fully automated:** One deployment per project is reproducible without manual intermediate steps.
4. **Upstream unchanged:** The original code is included as a Git submodule and not patched; adjustments are made exclusively via Helm values, overrides, and build configuration.

## Getting Started

Fresh clone (submodules included):

```bash
git clone --recurse-submodules https://github.com/aws-samples/sample-spark-demos.git
```

Existing clone — pull updates INCLUDING the submodule pointers:

```bash
git pull --recurse-submodules
git submodule update --init --recursive   # first time / after a pointer change
```

Tip: `git config submodule.recurse true` (once, per clone) makes every
`pull`/`checkout` handle the submodules automatically. The submodules are
read-only upstream code — never commit changes inside them.

Then:

```bash
cp .env.example .env        # central configuration; NEVER commit real values
# Fill in .env (AWS profile, region, Route53 zone, domain, ...)
make -C spark-workflow-demo apply       # SPARK Workflow (uses published upstream images)
make -C spark-api-demo bootstrap        # SPARK API (builds all images first: infra -> CodeBuild -> deploy)
```

All environment-specific values (account, profile, hosted zone, domains, sizing overrides) live exclusively in the untracked `.env`. The `.env.example` documents all keys with placeholder values.

| Project | Status | Docs |
|---|---|---|
| spark-workflow-demo | live, end-to-end verified incl. hands-off destroy/apply | [README](spark-workflow-demo/README.md) · [DEMO.md](spark-workflow-demo/DEMO.md) |
| spark-api-demo | live, end-to-end verified incl. hands-off destroy/bootstrap; OIDC perimeter + demo inspector | [README](spark-api-demo/README.md) · [DEMO.md](spark-api-demo/DEMO.md) |

## Security

[STRIDE threat model](docs/THREAT-MODEL.md) for the demo deployment layer:
assets with C/I/A ratings, trust boundaries, per-element STRIDE analysis
with evidence and row IDs, prioritised findings, explicitly accepted demo
risks, and the hardening checklist required before any production use. The
upstream submodules are third-party code — in scope is how this repository
builds, configures and exposes them.

Static analysis (checkov and semgrep over the Terraform, Helm, scripts and
the inspector in this repository) reports zero findings; every remaining
demo trade-off carries an inline suppression with its reason. Each project
README lists the hardening defaults in its section "Data protection and
hardening defaults".

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for how
to report a security issue.

## Contributing

See [CONTRIBUTING](CONTRIBUTING.md) and the
[Code of Conduct](CODE_OF_CONDUCT.md).

## Licenses

- The demo/infrastructure code in this repository is licensed under the **MIT-0 License**. See the [LICENSE](LICENSE) file.
- The included submodules **spark-workflow** and **spark-api** are licensed under **EUPL-1.2** and remain unchanged under their original license.
- Third-party notices per project: `spark-workflow-demo/THIRD_PARTY_NOTICES.md`, `spark-api-demo/THIRD_PARTY_NOTICES.md`.
