#!/usr/bin/env bash
# =============================================================================
# prepare-context.sh — CI workspace transformation for one SPARK API service
# (ADR 0001). Produces a buildable Docker build context from the unchanged
# upstream checkout:
#   1. Service directory → workspace
#   2. Shared libs to _vendor/ + path rewrite in pyproject.toml
#   3. Strip dev dependency group (test tooling; mistralai conflict)
#   4. Generate uv.lock (missing upstream)
#   5. Replace base image placeholders according to base-image-map.env
#
# Usage: prepare-context.sh <upstream-root> <service-rel-path> <out-dir>
# Example: prepare-context.sh ./spark-api 02-backend/norm-matching /tmp/ctx
# =============================================================================
set -euo pipefail

UPSTREAM_ROOT="$1"
SERVICE_PATH="$2"
OUT_DIR="$3"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAP_FILE="${BASE_IMAGE_MAP:-$SCRIPT_DIR/base-image-map.env}"

echo "==> Staging ${SERVICE_PATH} -> ${OUT_DIR}"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
cp -R "$UPSTREAM_ROOT/$SERVICE_PATH/." "$OUT_DIR/"

# --- 2.+3. Vendor path dependencies + strip dev group (Python services) ------
# Generic: finds path dependencies in ALL pyproject.toml files of the context
# (including nested workspace members like tex2pdf src/api) that point outside
# the context (../..../03-shared-services/*, ../<sibling-service>), copies
# the targets to _vendor/ and rewrites the paths relative to the respective
# pyproject.toml. Also strips the dev dependency group (ADR 0001).
if [ -f "$OUT_DIR/pyproject.toml" ]; then
  echo "==> Vendoring external path deps + stripping dev group"
  python3 - "$UPSTREAM_ROOT" "$SERVICE_PATH" "$OUT_DIR" <<'EOF'
import os, re, shutil, sys

upstream_root = os.path.abspath(sys.argv[1])
service_path  = sys.argv[2]  # relative to upstream_root — do NOT absolutize
out_dir       = os.path.abspath(sys.argv[3])
vendor_dir = os.path.join(out_dir, "_vendor")

for dirpath, _dirs, files in os.walk(out_dir):
    if "_vendor" in os.path.relpath(dirpath, out_dir).split(os.sep):
        continue
    if "pyproject.toml" not in files:
        continue
    pp = os.path.join(dirpath, "pyproject.toml")
    src = open(pp).read()

    # Strip dev group (test tooling; fixes, among others, the mistralai
    # conflict). Line-based with bracket counting — the earlier regex
    # corrupted pyproject files whose dev list contains nested brackets
    # (observed: "Invalid metadata format"/"TOML parse error" in CodeBuild).
    # Replace the list with an EMPTY one instead of deleting it: other
    # groups reference it via { include-group = "dev" } and uv fails with
    # "malformed dependency groups" on dangling references (observed).
    def strip_dev_group(text):
        lines = text.splitlines(keepends=True)
        out, i, in_groups = [], 0, False
        while i < len(lines):
            line = lines[i]
            stripped = line.strip()
            if stripped.startswith("["):
                in_groups = stripped == "[dependency-groups]"
            if in_groups and re.match(r"^dev\s*=\s*\[", stripped):
                depth = line.count("[") - line.count("]")
                i += 1
                while depth > 0 and i < len(lines):
                    depth += lines[i].count("[") - lines[i].count("]")
                    i += 1
                out.append("dev = []\n")
                continue
            out.append(line)
            i += 1
        return "".join(out)

    src = strip_dev_group(src)

    rel_in_ctx = os.path.relpath(dirpath, out_dir)
    upstream_dir = os.path.normpath(os.path.join(upstream_root, service_path, rel_in_ctx))

    def rewrite(m):
        orig = m.group(1)
        if not orig.startswith(".."):
            return m.group(0)
        target = os.path.normpath(os.path.join(upstream_dir, orig))
        # Target inside the context? Then leave unchanged.
        ctx_upstream = os.path.normpath(os.path.join(upstream_root, service_path))
        if target.startswith(ctx_upstream + os.sep):
            return m.group(0)
        key = os.path.relpath(target, upstream_root)  # e.g. 03-shared-services/bizlog
        dest = os.path.join(vendor_dir, key)
        if not os.path.exists(dest):
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            shutil.copytree(target, dest)
        new_rel = os.path.relpath(dest, dirpath)
        return f'path = "{new_rel}"'

    src = re.sub(r'path = "([^"]+)"', rewrite, src)
    open(pp, "w").write(src)
    print(f"    rewrote {os.path.relpath(pp, out_dir)}")
EOF
fi

# --- 3b. Copy the vendored deps into the Dockerfile uv-sync stages -----------
# Upstream RUN lines bind-mount only uv.lock + pyproject.toml, so path deps
# under _vendor/ are invisible during `uv sync` (observed in CodeBuild:
# "Failed to generate package metadata for ... directory+_vendor/...").
# A COPY right after each WORKDIR /app makes them available AND writable
# (setuptools writes egg-info during the wheel build — bind mounts failed
# with "Read-only file system"/"Permission denied"; editing the RUN mount
# chains also broke Dockerfiles whose mounts sit on a single line).
if [ -d "$OUT_DIR/_vendor" ] && [ -f "$OUT_DIR/Dockerfile" ]; then
  echo "==> Adding 'COPY _vendor' after WORKDIR in Dockerfile uv stages"
  python3 - "$OUT_DIR/Dockerfile" <<'EOF'
import re, sys
path = sys.argv[1]
lines = open(path).read().splitlines(keepends=True)
out = []
for line in lines:
    out.append(line)
    if re.match(r"^\s*WORKDIR\s+/app\s*$", line):
        # --chmod=0777: several Dockerfiles switch USER before the uv sync
        # (e.g. USER bmi_user); setuptools then writes egg-info into the
        # vendored sources (observed: "Permission denied" with plain COPY).
        out.append("COPY --chmod=0777 _vendor /app/_vendor\n")
open(path, "w").writelines(out)
EOF
fi

# --- 3c. Frontend: two files referenced by the build are not tracked in
# the upstream repo (verified with git ls-files; upstream-issue candidates):
#   - shell/.env.deployment (copied by the Dockerfile; runtime config comes
#     from docker-entrypoint.sh / window.ENV, so empty is fine)
#   - shared/src/cypress (re-exported by shared/src/index.ts; rollup fails
#     with "Could not resolve './cypress'") -> empty module stub
if grep -q "shell/.env.deployment" "$OUT_DIR/Dockerfile" 2>/dev/null && [ ! -f "$OUT_DIR/shell/.env.deployment" ]; then
  echo "==> Creating shell/.env.deployment with root-relative federation remotes"
  # The module-federation remote URLs are resolved at BUILD time from
  # VITE_MFE_*_URL (shell/vite.config.ts loadEnv) — window.ENV covers only
  # the API URLs at runtime. An empty stub baked the localhost dev
  # defaults into the bundle (observed in the browser: "Microfrontend
  # Unavailable — Failed to fetch ... http://localhost:5002/assets/
  # remoteEntry.js"). Root-relative URLs keep the image env-agnostic; the
  # demo ingress serves every MFE dist under /<mfe>/ on the same origin.
  # mfe1/mfe-rte are referenced by the shell but not shipped in the image
  # (upstream Dockerfile copies neither dist) — their entries stay
  # consistent and surface as the shell's own unavailable-fallback.
  cat > "$OUT_DIR/shell/.env.deployment" <<'ENVEOF'
VITE_MFE1_URL=/mfe1/assets/remoteEntry.js
VITE_MFE_FP_URL=/mfe-fp/assets/remoteEntry.js
VITE_MFE_WS_URL=/mfe-ws/assets/remoteEntry.js
VITE_MFE_VERWALTUNGSAKT_URL=/mfe-verwaltungsakt/assets/remoteEntry.js
VITE_MFE_MP_URL=/mfe-mp/assets/remoteEntry.js
VITE_MFE_VP_URL=/mfe-vp/assets/remoteEntry.js
VITE_MFE_RTE_URL=/mfe-rte/assets/remoteEntry.js
VITE_MFE_KP_URL=/mfe-kp/assets/remoteEntry.js
ENVEOF
fi
if grep -q "from './cypress'" "$OUT_DIR/shared/src/index.ts" 2>/dev/null \
   && [ ! -e "$OUT_DIR/shared/src/cypress" ] && [ ! -e "$OUT_DIR/shared/src/cypress.ts" ]; then
  echo "==> Stubbing shared/src/cypress (referenced but not tracked upstream)"
  mkdir -p "$OUT_DIR/shared/src/cypress"
  printf 'export {};\n' > "$OUT_DIR/shared/src/cypress/index.ts"
fi

# tex2pdf-service COPYs CHANGELOG.md, which is not tracked inside the
# service directory upstream (observed: checksum "not found"). An empty
# stub satisfies the COPY; the file is display-only.
if grep -qE "^COPY CHANGELOG.md" "$OUT_DIR/Dockerfile" 2>/dev/null && [ ! -f "$OUT_DIR/CHANGELOG.md" ]; then
  echo "==> Stubbing CHANGELOG.md (copied but not tracked upstream)"
  touch "$OUT_DIR/CHANGELOG.md"
fi

# tex2pdf-service's default render option references the logo 'brd.png',
# which upstream does not ship (the logo directory carries only a README —
# presumably the federal eagle cannot be redistributed). Without it every
# Bescheid render 400s ("Bescheid data validation failed", underlying
# ValueError "Logo file not found: 'brd.png'"). Generate a neutral solid
# demo placeholder PNG at build time (stdlib only, no Pillow in the CI).
if [ -d "$OUT_DIR/bescheid_templates/assets/logo" ] \
   && [ ! -f "$OUT_DIR/bescheid_templates/assets/logo/brd.png" ]; then
  echo "==> Generating neutral demo logo brd.png (upstream ships none)"
  python3 - "$OUT_DIR/bescheid_templates/assets/logo/brd.png" <<'EOF'
import struct, sys, zlib

W = H = 96
# Solid slate-blue square as a neutral placeholder emblem.
row = b"\x00" + bytes([71, 91, 128, 255]) * W
raw = row * H

def chunk(tag: bytes, data: bytes) -> bytes:
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

png = (b"\x89PNG\r\n\x1a\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 6, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(raw, 9))
       + chunk(b"IEND", b""))
open(sys.argv[1], "wb").write(png)
EOF
fi

# --- 3d. Vendored packages importing a release-time _version.py ---------------
# bmds-prompt-security's __init__ does `from ._version import __version__`,
# but the file is generated by the upstream release CI and not tracked
# (observed at runtime: ModuleNotFoundError bmds_prompt_security._version).
# Generate a static stub for every vendored package with that pattern.
if [ -d "$OUT_DIR/_vendor" ]; then
  python3 - "$OUT_DIR/_vendor" <<'EOF'
import os, re, sys
vendor = sys.argv[1]
for root, dirs, files in os.walk(vendor):
    if "__init__.py" not in files:
        continue
    init = os.path.join(root, "__init__.py")
    try:
        text = open(init).read()
    except OSError:
        continue
    if re.search(r"from\s+\.\s*_version\s+import|from\s+\._version\s+import", text):
        vfile = os.path.join(root, "_version.py")
        if not os.path.exists(vfile):
            open(vfile, "w").write('__version__ = "0.0.0"\nversion = "0.0.0"\n__version_tuple__ = (0, 0, 0)\nversion_tuple = (0, 0, 0)\n')
            print(f"    stubbed {os.path.relpath(vfile, vendor)}")
        # hatchling honors .gitignore during wheel builds — the upstream
        # package ignores its release-generated _version.py, so the stub
        # was silently excluded from the wheel (verified: unzip -l).
        # Walk up to the package root and drop matching ignore lines.
        d = root
        while d.startswith(vendor):
            gi = os.path.join(d, ".gitignore")
            if os.path.exists(gi):
                gilines = open(gi).read().splitlines(keepends=True)
                kept = [l for l in gilines if "_version.py" not in l]
                if len(kept) != len(gilines):
                    open(gi, "w").writelines(kept)
                    print(f"    un-ignored _version.py in {os.path.relpath(gi, vendor)}")
            d = os.path.dirname(d)
EOF
fi

# mfe-vp's vite build parses mfe-ewm/shared/tsconfig.json via
# tsconfig-paths; the file is not tracked upstream (observed: ENOENT).
if [ -d "$OUT_DIR/mfe-ewm" ] && [ ! -f "$OUT_DIR/mfe-ewm/shared/tsconfig.json" ]; then
  echo "==> Stubbing mfe-ewm/shared/tsconfig.json (referenced but not tracked upstream)"
  mkdir -p "$OUT_DIR/mfe-ewm/shared"
  printf '{"compilerOptions": {}}\n' > "$OUT_DIR/mfe-ewm/shared/tsconfig.json"
fi

# shell's Router.tsx imports pages/abstandsmessung/Abstandsmessung, but the
# page directory is not tracked upstream (observed: rollup "Could not
# resolve ../../pages/abstandsmessung/Abstandsmessung" fails the shell
# build; the parallel `& ... wait` RUN swallows the exit code and the
# failure only surfaces at COPY /app/shell/dist). Minimal placeholder
# component; the route stays reachable but empty (upstream-issue candidate).
if grep -q "pages/abstandsmessung/Abstandsmessung" "$OUT_DIR/shell/src/components/Router/Router.tsx" 2>/dev/null \
   && [ ! -e "$OUT_DIR/shell/src/pages/abstandsmessung" ]; then
  echo "==> Stubbing shell/src/pages/abstandsmessung (referenced but not tracked upstream)"
  mkdir -p "$OUT_DIR/shell/src/pages/abstandsmessung"
  cat > "$OUT_DIR/shell/src/pages/abstandsmessung/Abstandsmessung.tsx" <<'TSX'
// Demo CI stub: the upstream repo references this page from Router.tsx but
// does not track it. Renders nothing; keeps tsc + rollup green.
export default function Abstandsmessung() {
  return null;
}
TSX
fi

# dokumentenpruefung imports dokumentenpruefung.sample_data
# (SAMPLE_SOLL_DOKUMENTE) in a router's OpenAPI example — the module is
# not tracked upstream (observed at runtime: ModuleNotFoundError
# 'dokumentenpruefung.sample_data' crashloop). defaultdict(list) keeps any
# key lookup in import-time examples working (upstream-issue candidate).
if grep -rq "from dokumentenpruefung.sample_data import" "$OUT_DIR/src" 2>/dev/null \
   && [ ! -e "$OUT_DIR/src/dokumentenpruefung/sample_data.py" ] \
   && [ ! -e "$OUT_DIR/src/dokumentenpruefung/sample_data" ]; then
  echo "==> Stubbing dokumentenpruefung/sample_data.py (imported but not tracked upstream)"
  cat > "$OUT_DIR/src/dokumentenpruefung/sample_data.py" <<'PYEOF'
"""Demo CI stub: upstream imports this module but does not track it."""
from collections import defaultdict

SAMPLE_SOLL_DOKUMENTE: "defaultdict[str, list]" = defaultdict(list)
PYEOF
fi

# --- 3e0. Frontend: the v0.5.1 root package-lock.json is rejected by npm 10
# (bundled with node:20-bookworm): the workspaces pin `@hey-api/openapi-ts
# ^0.80.8` while the lock only carries the hoisted 0.97.3, and npm 10's
# `npm ci` refuses with "package.json and package-lock.json are not in sync
# / Missing: @hey-api/openapi-ts@0.80.18 from lock file" (observed in
# CodeBuild; reproduced with npm 10.8.2 on the pristine export). npm 11
# accepts the same lock unchanged (verified: `npm ci --dry-run` green with
# 11.19.0), so the builder stage upgrades npm before `npm ci` instead of
# regenerating the lock — the upstream lock stays authoritative
# (upstream-issue candidate: lock drift against the workspaces).
if grep -qE '^RUN npm ci' "$OUT_DIR/Dockerfile" 2>/dev/null && [ -f "$OUT_DIR/package-lock.json" ] \
   && ! grep -qE 'npm install -g npm@' "$OUT_DIR/Dockerfile"; then
  echo "==> Pinning npm 11 in the builder stage before 'npm ci' (lock rejected by npm 10)"
  sed -i.bak -E '0,/^RUN npm ci/s//RUN npm install -g npm@11.19.0 --no-audit --no-fund\nRUN npm ci/' "$OUT_DIR/Dockerfile"
  rm -f "$OUT_DIR/Dockerfile.bak"
fi

# --- 3e. Frontend: api-gen:* npm scripts re-generate TS clients from
# OpenAPI spec files that the upstream CI exports from running services —
# the yml files are not tracked (observed: ENOENT norm-matching-openapi.yml)
# while the GENERATED clients ARE tracked (verified: api/generated/**).
# Turn the refresh scripts into no-ops in the CI workspace.
if [ -d "$OUT_DIR/shell" ] && [ -f "$OUT_DIR/package.json" ]; then
  echo "==> Neutralizing api-gen:* scripts (generated clients are tracked)"
  python3 - "$OUT_DIR" <<'EOF'
import json, os, sys
root = sys.argv[1]
for dirpath, dirs, files in os.walk(root):
    if "node_modules" in dirpath:
        continue
    if "package.json" not in files:
        continue
    p = os.path.join(dirpath, "package.json")
    with open(p) as f:
        try:
            data = json.load(f)
        except Exception:
            continue
    scripts = data.get("scripts") or {}
    changed = False
    for k in list(scripts):
        if k.startswith("api-gen") or k == "api-gen":
            # NOTE: no shell metacharacters here — npm runs this via sh -c
            # (observed: parentheses broke the no-op itself).
            scripts[k] = "echo skipped api-gen - demo CI, specs not tracked upstream"
            changed = True
        # Some MFEs chain "npm run api-gen && vite build" — keep those
        # intact; the api-gen target itself is already a no-op above.
    if changed:
        with open(p, "w") as f:
            json.dump(data, f, indent=2)
        print(f"    patched {os.path.relpath(p, root)}")
EOF
fi

# --- 3f. Vendored stub lagging behind its callers -----------------------------
# decision-protocol-stub declares AutomaticStepOrigin(system_id,
# model_version) while a consumer constructs it with service_version —
# inconsistent within the same upstream revision (observed at runtime:
# 500 on decision-document creation, "AutomaticStepOrigin.__init__() got
# an unexpected keyword argument 'service_version'"). Adds the missing
# optional field to the vendored copy; additive and last in the dataclass,
# so positional construction stays valid (upstream-issue candidate).
if [ -d "$OUT_DIR/_vendor" ]; then
  python3 - "$OUT_DIR/_vendor" <<'EOF'
import os, re, sys

vendor = sys.argv[1]
for root, _dirs, files in os.walk(vendor):
    for name in files:
        if name != "__init__.py":
            continue
        path = os.path.join(root, name)
        text = open(path).read()
        m = re.search(r"class AutomaticStepOrigin:\n((?:[ \t]+.*\n|\n)*)", text)
        if not m or "service_version" in m.group(1):
            continue
        body = m.group(1)
        fields = [l for l in body.splitlines() if l.strip() and not l.strip().startswith("#")]
        indent = re.match(r"\s*", fields[-1]).group(0) if fields else "    "
        patched = body.rstrip("\n") + f"\n{indent}service_version: str | None = None\n"
        text = text[: m.start(1)] + patched + text[m.end(1) :]
        open(path, "w").write(text)
        print(f"    added service_version to AutomaticStepOrigin in {os.path.relpath(path, vendor)}")
EOF
fi

# --- 3f2. dokumentenpruefung's decision-step helper lagging behind the shared lib
# decision-protocol v0.5.1 made CaseRef.proposal_id the mandatory UUID anchor
# and application_id an optional UUID, but dokumentenpruefung's helper still
# falls back to its service name for a missing application id — and every
# caller passes None (observed on v0.5.1: every Vollstaendigkeits-/
# Kohaerenzpruefung start answered 500 "1 validation error for CaseRef /
# application_id / Input should be a valid UUID ... input_value=
# 'dokumentenpruefung'"). Two AI call sites (plausibility result, consistency
# analysis) pass NO id at all, so with the fallback gone CaseRef fails on
# proposal_id (observed: "UUID input should be a string, bytes or UUID object
# ... input_value=None", plausibility check FEHLER). Pass the optional id
# through unchanged, and skip the decision step (not the check) when there is
# no case anchor to attach it to; the business audit event emitted right
# before each of these steps still flows. Upstream-issue candidate.
if [ -f "$OUT_DIR/src/dokumentenpruefung/helpers/decision_protocol.py" ]; then
  python3 - "$OUT_DIR/src/dokumentenpruefung/helpers/decision_protocol.py" <<'EOF'
import sys
path = sys.argv[1]
text = open(path).read()
changed = False
needle = "    case_ref = CaseRef(\n        application_id=application_id or config.SERVICE_NAME,\n        proposal_id=proposal_id,\n    )\n"
patched = ("    if proposal_id is None and application_id is None:\n"
           "        # Demo CI shim: no case anchor for this step (upstream call site\n"
           "        # passes neither id); the step is skipped, the check continues.\n"
           "        return None\n"
           "    case_ref = CaseRef(\n        application_id=application_id,\n        proposal_id=proposal_id,\n    )\n")
if needle in text:
    text = text.replace(needle, patched); changed = True
emit_needle = '    """Emit a decision step through the audit-safe logger. Never raises."""\n'
emit_patched = emit_needle + "    if step is None:\n        return\n"
if emit_needle in text and "    if step is None:\n        return\n" not in text:
    text = text.replace(emit_needle, emit_patched, 1); changed = True
text = text.replace(") -> DecisionStep:\n    \"\"\"Build a decision step for an AI decision.\"\"\"", ") -> DecisionStep | None:\n    \"\"\"Build a decision step for an AI decision.\"\"\"")
text = text.replace(") -> DecisionStep:\n    \"\"\"Build a decision step for a human decision.\"\"\"", ") -> DecisionStep | None:\n    \"\"\"Build a decision step for a human decision.\"\"\"")
text = text.replace("def emit_decision_step(\n    step: DecisionStep, *,", "def emit_decision_step(\n    step: \"DecisionStep | None\", *,")
if changed:
    open(path, "w").write(text)
    print("    patched helpers/decision_protocol.py: optional application_id, no-anchor steps skipped")
EOF
fi

# --- 3g. Resolver constraints for the generated locks ----------------------------
# Upstream ships no lock and most services pin only lower bounds, so `uv lock`
# picks the newest release and a new upstream release of a library can break
# the cold start without any change in the submodule (observed on the first
# v0.5.1 batch):
# - SQLAlchemy 2.1 moved greenlet out of the default dependencies and made
#   psycopg (3) the default postgresql driver: every asyncio engine failed at
#   import ("The SQLAlchemy asyncio module requires that the Python 'greenlet'
#   library is installed" — fristenmanagement, decision-log-store-service) and
#   the psycopg2-based services crashed with "No module named 'psycopg'"
#   (ki-guv-ai-testing, ki-guv-explainability).
# - FastAPI 0.145 removed the `**extra` kwargs of FastAPI(); dokumentenpruefung
#   passes `components={...}` (observed: TypeError "FastAPI.__init__() got an
#   unexpected keyword argument 'components'"). 0.144 is the last release that
#   accepts it (bisected on this host).
# Both constraints keep the resolver on the lines the upstream code was
# developed against (upstream-issue candidates: upper bounds or a lock file).
if [ -f "$OUT_DIR/pyproject.toml" ]; then
  echo "==> Adding uv constraint-dependencies (sqlalchemy<2.1, fastapi<0.145)"
  python3 - "$OUT_DIR/pyproject.toml" <<'EOF'
import re, sys
path = sys.argv[1]
text = open(path).read()
pins = ['"sqlalchemy<2.1"', '"fastapi<0.145"']
missing = [p for p in pins if p.strip('"') not in text]
if not missing:
    sys.exit(0)
m = re.search(r"^constraint-dependencies\s*=\s*\[", text, re.M)
if m:
    # Extend the existing list (e.g. decision-log-store-service constrains
    # starlette); valid for single- and multi-line lists.
    text = text[: m.end()] + "".join(f"\n    {p}," for p in missing) + text[m.end():]
    open(path, "w").write(text)
    sys.exit(0)
constraint = "constraint-dependencies = [" + ", ".join(missing) + "]\n"
m = re.search(r"^\[tool\.uv\]\s*$", text, re.M)
if m:
    text = text[: m.end()] + "\n" + constraint + text[m.end():]
else:
    text = text.rstrip("\n") + "\n\n[tool.uv]\n" + constraint
open(path, "w").write(text)
EOF
fi

# --- 3h. Vendored bizlog NoOpLogger lagging behind a caller ---------------------
# dokumentenpruefung's bizlog_wrapper calls logger.setLevel() on the bizlog
# logger; structlog's BoundLogger proxies any attribute to the wrapped
# NoOpLogger, which has no setLevel (observed at import: AttributeError
# "'NoOpLogger' object has no attribute 'setLevel'" crashloop). A no-op
# setLevel on the vendored copy keeps the wrapper's intent (levels are
# meaningless on a no-op sink). Upstream-issue candidate.
if [ -f "$OUT_DIR/_vendor/03-shared-services/bizlog/src/bizlog/rabbitmq.py" ]; then
  python3 - "$OUT_DIR/_vendor/03-shared-services/bizlog/src/bizlog/rabbitmq.py" <<'EOF'
import re, sys
path = sys.argv[1]
text = open(path).read()
if "def setLevel" not in text:
    m = re.search(r"^class NoOpLogger:\n(?:    .*\n|\n)*?(?=    def debug\()", text, re.M)
    if m:
        text = text[: m.end()] + "    def setLevel(self, *_args: object, **_kwargs: object) -> None:\n        \"\"\"Demo CI shim: levels are meaningless on a no-op sink.\"\"\"\n\n" + text[m.end():]
        open(path, "w").write(text)
        print("    added NoOpLogger.setLevel to vendored bizlog")
EOF
fi

# --- 4. Generate uv.lock (missing upstream) ------------------------------------
if [ -f "$OUT_DIR/pyproject.toml" ] && [ ! -f "$OUT_DIR/uv.lock" ]; then
  echo "==> Generating uv.lock"
  (cd "$OUT_DIR" && uv lock)
fi

# --- 5. Replace base image references -------------------------------------------
# Each map row rewrites (a) the upstream placeholder `<CONTAINER_REGISTRY>/<ref>`
# wherever it appears and (b) a bare `FROM <ref>` / `FROM docker.io/<ref>`
# line. Since v0.5.1 the frontend (node, nginx-unprivileged), request-proxy and
# ki-guv-feedback (python) Dockerfiles reference Docker Hub without the
# placeholder; rewriting them keeps every pull on public.ecr.aws/ghcr.io
# instead of the anonymous Docker Hub rate limit shared by the NAT address.
if [ -f "$OUT_DIR/Dockerfile" ]; then
  echo "==> Rewriting base image references"
  while IFS='=' read -r placeholder image; do
    [[ "$placeholder" =~ ^#.*$ || -z "$placeholder" ]] && continue
    sed -i.bak "s|<CONTAINER_REGISTRY>/${placeholder}|${image}|g" "$OUT_DIR/Dockerfile"
    # Bare FROM: anchor on the whole reference (escaped dots), keep the
    # optional "AS <stage>" tail and tolerate trailing whitespace.
    esc=$(printf '%s' "$placeholder" | sed -e 's/[.]/\\./g')
    sed -i.bak -E "s#^(FROM[[:space:]]+)(docker\.io/)?${esc}([[:space:]]|\$)#\1${image}\3#" "$OUT_DIR/Dockerfile"
  done < "$MAP_FILE"
  rm -f "$OUT_DIR/Dockerfile.bak"

  if grep -q '<CONTAINER_REGISTRY>' "$OUT_DIR/Dockerfile"; then
    echo "ERROR: Unresolved placeholders in Dockerfile:" >&2
    grep '<CONTAINER_REGISTRY>' "$OUT_DIR/Dockerfile" >&2
    exit 1
  fi

  # The test-deps stage is dropped (dev group stripped); build secrets for the
  # private UV_INDEX are not needed (vendor approach) — remove the mount
  # EXPRESSIONS only, never whole lines: in several Dockerfiles the secret
  # mount OPENS the RUN instruction, so deleting the line ate the RUN
  # keyword (observed: "unknown instruction: --mount/uv").
  sed -i.bak -E 's/--mount=type=secret,id=TECHNICAL_USER[^ ]*[[:space:]]*//g' "$OUT_DIR/Dockerfile"
  rm -f "$OUT_DIR/Dockerfile.bak"
fi

echo "==> Context ready: $OUT_DIR"
