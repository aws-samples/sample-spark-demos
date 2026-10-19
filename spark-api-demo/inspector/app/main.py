"""Demo inspector backend — MIT-0 demo tooling, not part of the upstream product.

Aggregates backend activity into one SSE stream so the browser overlay can
show what happens *behind* the SPARK API while the demo runs:

  - LiteLLM request log (/spend/logs): every LLM call the services make,
    with model, tokens and latency — the moment Amazon Bedrock enters.
  - RabbitMQ management API: queues, consumers, message rates.
  - CloudWatch AWS/Bedrock: invocation counts per model (the AWS-side proof).

Read-only against every source; polls with small intervals; one poll loop
per SSE client (demo scale).
"""

import asyncio
import datetime as dt
import json
import logging
import os
from typing import Any, AsyncGenerator

import boto3
import botocore.exceptions
import httpx
from fastapi import FastAPI
from fastapi.responses import FileResponse, HTMLResponse, StreamingResponse

logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"))
log = logging.getLogger("demo-inspector")

LITELLM_BASE = os.environ.get("LITELLM_BASE", "")
LITELLM_MASTER_KEY = os.environ.get("LITELLM_MASTER_KEY", "")
RABBITMQ_MGMT_URL = os.environ.get("RABBITMQ_MGMT_URL", "")
RABBITMQ_USER = os.environ.get("RABBITMQ_USER", "")
RABBITMQ_PASSWORD = os.environ.get("RABBITMQ_PASSWORD", "")
BEDROCK_REGION = os.environ.get("BEDROCK_REGION", "eu-central-1")
POLL_SECONDS = float(os.environ.get("POLL_SECONDS", "5"))

app = FastAPI()
STATIC_DIR = os.path.join(os.path.dirname(__file__), "static")


@app.get("/demo-inspector/health")
def health() -> dict:
    return {"status": "ok"}


@app.get("/demo-inspector/inspector.js")
def inspector_js() -> FileResponse:
    return FileResponse(
        os.path.join(STATIC_DIR, "inspector.js"), media_type="application/javascript"
    )


@app.get("/demo-inspector/em-placeholder")
def em_placeholder(antrag: str = "") -> HTMLResponse:
    """Static stand-in for the Einwendungsmanagement iframe.

    The shell embeds MFE_EM_DYNAMIC_URL as an iframe and substitutes the
    literal substring 'antrag_id' with the current Antrag UUID. Upstream
    points this at the external demosplan platform, which is not part of
    the demo — without a target the sidebar entry rendered a broken
    frame. This page explains the gap instead.
    """
    import html

    safe_antrag = html.escape(antrag)[:64]
    body = f"""<!doctype html>
<html lang="de"><head><meta charset="utf-8"><title>Einwendungsmanagement</title>
<style>
  body {{ font-family: -apple-system, 'Segoe UI', Roboto, sans-serif;
         display: flex; align-items: center; justify-content: center;
         height: 100vh; margin: 0; background: #f4f4f4; color: #161616; }}
  .card {{ max-width: 34rem; background: #fff; border-left: 4px solid #47607f;
          padding: 2rem; box-shadow: 0 1px 3px rgba(0,0,0,.12); }}
  h1 {{ font-size: 1.1rem; margin: 0 0 .75rem; }}
  p  {{ font-size: .875rem; line-height: 1.5; margin: .5rem 0; }}
  code {{ background: #f4f4f4; padding: .1rem .3rem; font-size: .8rem; }}
</style></head><body>
<div class="card">
  <h1>Einwendungsmanagement &mdash; externes System</h1>
  <p>Dieses Modul wird upstream von der externen demosplan-Plattform
     bereitgestellt und ist nicht Teil dieser Demo-Umgebung.</p>
  <p>Die &uuml;brigen Module (Dokumente, Formelle Pr&uuml;fung, Materielle
     Pr&uuml;fung, Berichtskonfigurator) sind voll funktionsf&auml;hig.</p>
  <p>Aktueller Antrag: <code>{safe_antrag or "&mdash;"}</code></p>
</div>
</body></html>"""
    return HTMLResponse(body)


def _sse(event: dict[str, Any]) -> str:
    return f"data: {json.dumps(event, default=str)}\n\n"


def _public_error(exc: BaseException) -> str:
    """Fixed-vocabulary error category for the browser.

    The exception text itself never leaves the pod: httpx errors carry the
    internal service URL, botocore errors carry the caller ARN and account
    ID, and any traceback describes this process. The browser gets one of
    the constant strings below; the real exception goes to the pod log
    (see _report_source).
    """
    if isinstance(exc, httpx.TimeoutException):
        return "timed out"
    if isinstance(exc, httpx.TransportError):
        return "unreachable"
    if isinstance(exc, httpx.HTTPStatusError):
        code = exc.response.status_code
        if code in (401, 403):
            return "authentication failed"
        if code >= 500:
            return "upstream error"
        return "request rejected"
    if isinstance(exc, botocore.exceptions.ClientError):
        if exc.response.get("Error", {}).get("Code") in (
            "AccessDenied",
            "AccessDeniedException",
            "UnauthorizedOperation",
            "ExpiredToken",
            "ExpiredTokenException",
        ):
            return "access denied"
        return "aws api error"
    if isinstance(exc, botocore.exceptions.BotoCoreError):
        return "aws client error"
    return "unavailable"


class _SourceState:
    """Logs a source failure once per distinct failure (not on every 5 s
    poll) and the recovery once, server-side only."""

    def __init__(self) -> None:
        self._failing: dict[str, str] = {}

    def failed(self, source: str, exc: BaseException) -> dict[str, Any]:
        category = _public_error(exc)
        if self._failing.get(source) != category:
            self._failing[source] = category
            log.warning("source %s failed (%s): %r", source, category, exc, exc_info=exc)
        return {"type": "source_error", "source": source, "message": category}

    def recovered(self, source: str) -> None:
        if source in self._failing:
            del self._failing[source]
            log.info("source %s recovered", source)


async def _poll_litellm(client: httpx.AsyncClient, seen: set[str]) -> list[dict]:
    """New entries from the LiteLLM request log (each = one LLM call).

    NOTE: /spend/logs WITH start_date/end_date returns per-day AGGREGATES
    (observed: no request_id rows); the bare endpoint returns the raw
    request log. Full transfer per poll is fine at demo scale.
    """
    if not LITELLM_BASE:
        return []
    resp = await client.get(
        f"{LITELLM_BASE}/spend/logs",
        headers={"Authorization": f"Bearer {LITELLM_MASTER_KEY}"},
        timeout=8,
    )
    resp.raise_for_status()
    events = []
    for row in resp.json():
        rid = row.get("request_id")
        if not rid or rid in seen:
            continue
        seen.add(rid)
        events.append(
            {
                "type": "llm",
                "model": row.get("model"),
                "call_type": row.get("call_type"),
                "prompt_tokens": row.get("prompt_tokens"),
                "completion_tokens": row.get("completion_tokens"),
                "started_at": row.get("startTime"),
                "duration_ms": row.get("request_duration_ms")
                or _duration_ms(row.get("startTime"), row.get("endTime")),
            }
        )
    # Newest first for the panel.
    events.sort(key=lambda e: str(e.get("started_at")), reverse=True)
    return events


def _duration_ms(start: Any, end: Any) -> int | None:
    try:
        s = dt.datetime.fromisoformat(str(start))
        e = dt.datetime.fromisoformat(str(end))
        return int((e - s).total_seconds() * 1000)
    except Exception:
        return None


async def _poll_rabbitmq(client: httpx.AsyncClient) -> list[dict]:
    """Queue snapshot from the RabbitMQ management API."""
    if not RABBITMQ_MGMT_URL:
        return []
    resp = await client.get(
        f"{RABBITMQ_MGMT_URL}/api/queues",
        auth=(RABBITMQ_USER, RABBITMQ_PASSWORD),
        timeout=8,
    )
    resp.raise_for_status()
    queues = [
        {
            "name": q.get("name"),
            "messages": q.get("messages"),
            "consumers": q.get("consumers"),
            "publish_rate": (q.get("message_stats") or {}).get("publish_details", {}).get("rate", 0),
        }
        for q in resp.json()
    ]
    return [{"type": "rabbitmq", "queues": queues}]


def _poll_bedrock_sync() -> list[dict]:
    """Bedrock invocation sums of the last 10 minutes, per model."""
    cw = boto3.client("cloudwatch", region_name=BEDROCK_REGION)
    now = dt.datetime.now(dt.timezone.utc)
    metrics = cw.list_metrics(Namespace="AWS/Bedrock", MetricName="Invocations")["Metrics"]
    queries = []
    labels = {}
    for i, m in enumerate(metrics[:10]):
        model = next((d["Value"] for d in m["Dimensions"] if d["Name"] == "ModelId"), None)
        if not model:
            continue
        qid = f"m{i}"
        labels[qid] = model
        queries.append(
            {
                "Id": qid,
                "MetricStat": {
                    "Metric": {
                        "Namespace": "AWS/Bedrock",
                        "MetricName": "Invocations",
                        "Dimensions": m["Dimensions"],
                    },
                    "Period": 60,
                    "Stat": "Sum",
                },
            }
        )
    if not queries:
        return [{"type": "bedrock", "models": []}]
    data = cw.get_metric_data(
        MetricDataQueries=queries, StartTime=now - dt.timedelta(minutes=10), EndTime=now
    )
    models = [
        {"model": labels.get(r["Id"], r["Id"]), "invocations_10m": int(sum(r["Values"]))}
        for r in data["MetricDataResults"]
    ]
    return [{"type": "bedrock", "models": models}]


async def _event_stream() -> AsyncGenerator[str, None]:
    seen_llm: set[str] = set()
    state = _SourceState()
    yield _sse({"type": "hello", "poll_seconds": POLL_SECONDS})
    async with httpx.AsyncClient() as client:
        while True:
            for name, coro in (
                ("litellm", _poll_litellm(client, seen_llm)),
                ("rabbitmq", _poll_rabbitmq(client)),
            ):
                try:
                    for event in await coro:
                        yield _sse(event)
                    state.recovered(name)
                except Exception as exc:  # noqa: BLE001 — keep the stream alive
                    yield _sse(state.failed(name, exc))
            try:
                for event in await asyncio.to_thread(_poll_bedrock_sync):
                    yield _sse(event)
                state.recovered("bedrock")
            except Exception as exc:  # noqa: BLE001
                yield _sse(state.failed("bedrock", exc))
            await asyncio.sleep(POLL_SECONDS)


@app.get("/demo-inspector/events")
def events() -> StreamingResponse:
    return StreamingResponse(
        _event_stream(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )
