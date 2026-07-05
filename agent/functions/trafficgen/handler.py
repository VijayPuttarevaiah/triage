import json
import os
import random
import time
import urllib.request
import uuid

BASE_URL = os.environ["PAYFLOW_URL"].rstrip("/")
REQUESTS_PER_INVOCATION = int(os.environ.get("REQUESTS_PER_INVOCATION", "60"))


def _request(method, path, body=None):
    url = f"{BASE_URL}{path}"
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return resp.status
    except urllib.error.HTTPError as e:
        return e.code
    except Exception:
        return 0


def handler(event, context):
    ok, failed = 0, 0
    for _ in range(REQUESTS_PER_INVOCATION):
        if random.random() < 0.7:
            status = _request("POST", "/transactions", {"amount": round(random.uniform(1, 500), 2), "txn_id": str(uuid.uuid4())})
        else:
            status = _request("GET", "/health")
        if 200 <= status < 300:
            ok += 1
        else:
            failed += 1
        time.sleep(random.uniform(0.2, 0.8))

    return {"ok": ok, "failed": failed}
