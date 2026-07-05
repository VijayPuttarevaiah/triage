#!/usr/bin/env bash
# PayFlow local smoke test. Usage: ./smoke-test.sh [base_url]
# Default target is the local docker container.
set -e
BASE="${1:-http://localhost:8080}"

echo "── 1. Health check"
curl -s -o /dev/null -w "GET /health -> %{http_code}\n" "$BASE/health"

echo "── 2. Create transaction (will 500 locally without AWS creds/table - that's expected; verify route exists)"
curl -s -o /dev/null -w "POST /transactions -> %{http_code}\n" -X POST "$BASE/transactions" \
  -H 'Content-Type: application/json' -d '{"amount": 42.50}'

echo "── 3. Enable error storm"
curl -s -X POST "$BASE/chaos/errors" && echo
curl -s -o /dev/null -w "POST /transactions during storm -> %{http_code} (expect 500)\n" \
  -X POST "$BASE/transactions" -H 'Content-Type: application/json' -d '{}'
curl -s -o /dev/null -w "GET /health during storm -> %{http_code} (expect 200 - health is exempt)\n" "$BASE/health"

echo "── 4. Reset"
curl -s -X POST "$BASE/chaos/reset" && echo

echo "── 5. Latency injection"
curl -s -X POST "$BASE/chaos/latency" && echo
curl -s -o /dev/null -w "POST /transactions with latency -> %{time_total}s total (expect ~3s+)\n" \
  -X POST "$BASE/transactions" -H 'Content-Type: application/json' -d '{}'
curl -s -X POST "$BASE/chaos/reset" && echo

echo "── Done. (/chaos/crash not tested here - it kills the container; test it once manually.)"
