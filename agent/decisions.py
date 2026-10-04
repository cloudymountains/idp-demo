"""Where the agent's decisions go: the same decision log the pipeline writes.

Three sinks, picked by environment:

  DECISION_LOG_ENDPOINT=http://dynamodb:8000   DynamoDB Local, the compose setup
  DECISION_LOG=dynamodb                        the real table, default credentials
  neither                                      a JSONL file, so it works on a laptop

Like the pipeline's log, this never raises. An audit trail that can block a
request is a liability.
"""

from __future__ import annotations

import datetime as dt
import json
import os
import pathlib
import sys
import uuid

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "platform" / "bin"))

from decision_log import TABLE, manifest_facts  # noqa: E402

ACTOR = "platform-agent"


def _file() -> pathlib.Path:
    return pathlib.Path(os.environ.get("AGENT_DECISIONS_FILE", HERE / ".decisions.jsonl"))


def _table():
    import boto3

    endpoint = os.environ.get("DECISION_LOG_ENDPOINT")
    if not endpoint:
        return boto3.resource("dynamodb").Table(TABLE)

    # DynamoDB Local accepts any credentials. Passing them here, rather than
    # through the environment, keeps them away from the model client.
    ddb = boto3.resource(
        "dynamodb", endpoint_url=endpoint, region_name="eu-west-1",
        aws_access_key_id="local", aws_secret_access_key="local",
    )
    if TABLE not in [t.name for t in ddb.tables.all()]:
        ddb.create_table(
            TableName=TABLE, BillingMode="PAY_PER_REQUEST",
            KeySchema=[{"AttributeName": "pk", "KeyType": "HASH"}, {"AttributeName": "sk", "KeyType": "RANGE"}],
            AttributeDefinitions=[{"AttributeName": "pk", "AttributeType": "S"}, {"AttributeName": "sk", "AttributeType": "S"}],
        ).wait_until_exists()
    return ddb.Table(TABLE)


def _remote() -> bool:
    return bool(os.environ.get("DECISION_LOG_ENDPOINT")) or os.environ.get("DECISION_LOG") == "dynamodb"


def record(manifest: pathlib.Path, phase: str, verdict: str, intent: str, detail: str = "") -> dict | None:
    try:
        facts = manifest_facts(manifest)
    except Exception:  # noqa: BLE001  a manifest too broken to parse is still worth logging
        facts = {"service": manifest.parent.name, "environment": "unknown", "manifest": manifest.read_text()}

    moment = dt.datetime.now(dt.timezone.utc)
    now = moment.isoformat(timespec="seconds")
    item = {
        "pk": f"{facts['environment']}#{facts['service']}",
        # Microseconds in the sort key, so one run's records read back in order.
        "sk": f"{moment.isoformat(timespec='microseconds')}#{uuid.uuid4().hex[:8]}",
        "timestamp": now,
        "phase": phase,
        "verdict": verdict,
        "intent": intent,
        "actor": ACTOR,
        **facts,
    }
    if detail:
        item["detail"] = detail

    try:
        if _remote():
            _table().put_item(Item=item)
        else:
            with _file().open("a") as fh:
                fh.write(json.dumps(item) + "\n")
    except Exception as exc:  # noqa: BLE001
        print(f"WARN    decision not logged: {exc}", file=sys.stderr)
        return None
    return item


def recent(service: str, environment: str = "dev", limit: int = 20) -> list[dict]:
    pk = f"{environment}#{service}"
    try:
        if _remote():
            from boto3.dynamodb.conditions import Key

            items = _table().query(
                KeyConditionExpression=Key("pk").eq(pk), ScanIndexForward=False, Limit=limit,
            ).get("Items", [])
        else:
            lines = _file().read_text().splitlines() if _file().exists() else []
            items = [i for i in map(json.loads, lines) if i["pk"] == pk][::-1][:limit]
    except Exception as exc:  # noqa: BLE001
        print(f"WARN    decision log unreadable: {exc}", file=sys.stderr)
        return []
    keep = ("timestamp", "phase", "verdict", "intent", "detail", "actor")
    return [{k: i[k] for k in keep if k in i} for i in items]


def everything() -> list[dict]:
    """Every record, oldest first. A scan: fine for a memory of this size."""
    try:
        if _remote():
            table, items, kwargs = _table(), [], {}
            while True:
                page = table.scan(**kwargs)
                items += page.get("Items", [])
                if "LastEvaluatedKey" not in page:
                    break
                kwargs = {"ExclusiveStartKey": page["LastEvaluatedKey"]}
        else:
            lines = _file().read_text().splitlines() if _file().exists() else []
            items = [json.loads(line) for line in lines]
    except Exception as exc:  # noqa: BLE001
        print(f"WARN    decision log unreadable: {exc}", file=sys.stderr)
        return []
    return sorted(items, key=lambda i: i.get("sk", ""))
