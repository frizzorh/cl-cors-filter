#!/usr/bin/env bash
# Test Gateway API echo service, including CORS preflight (OPTIONS).
#
# Usage:
#   ./scripts/test-echo-cors.sh
#   HOST=echo.example.com ORIGIN=https://myapp.example.com ./scripts/test-echo-cors.sh
set -euo pipefail

HOST="${HOST:-echo.gwapi.apps.cluster-k5msd.dyn.redhatworkshops.io}"
BASE_URL="${BASE_URL:-https://${HOST}}"
ORIGIN="${ORIGIN:-https://app.example.com}"
CURL_OPTS=(-skS --connect-timeout 15 --max-time 30)
NS="${NS:-echo-demo}"

pass=0
fail=0

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }

assert_status() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    green "  PASS  ${name} (HTTP ${actual})"
    pass=$((pass + 1))
  else
    red "  FAIL  ${name} (expected HTTP ${expected}, got ${actual})"
    fail=$((fail + 1))
  fi
}

assert_header() {
  local name="$1" headers="$2" header="$3" expected="$4"
  local value
  value="$(printf '%s\n' "$headers" | awk -F': ' -v h="$(printf '%s' "$header" | tr '[:upper:]' '[:lower:]')" '
    tolower($1) == h {
      sub(/\r$/, "", $2)
      print $2
      exit
    }
  ')"
  if [[ "$value" == "$expected" ]]; then
    green "  PASS  ${name}: ${header}=${value}"
    pass=$((pass + 1))
  else
    red "  FAIL  ${name}: ${header} (expected '${expected}', got '${value:-<missing>}')"
    fail=$((fail + 1))
  fi
}

assert_body_contains() {
  local name="$1" body="$2" needle="$3"
  if printf '%s' "$body" | grep -Fq "$needle"; then
    green "  PASS  ${name}"
    pass=$((pass + 1))
  else
    red "  FAIL  ${name} (missing '${needle}')"
    fail=$((fail + 1))
  fi
}

assert_body_empty() {
  local name="$1" body="$2"
  if [[ -z "$body" ]]; then
    green "  PASS  ${name} (empty body)"
    pass=$((pass + 1))
  else
    red "  FAIL  ${name} (expected empty body, got ${#body} bytes — backend may have been hit)"
    fail=$((fail + 1))
  fi
}

do_curl() {
  # Sets globals: _code _headers _body
  local method="$1"
  shift
  local hdr_file body_file
  hdr_file="$(mktemp)"
  body_file="$(mktemp)"
  _code="$(curl "${CURL_OPTS[@]}" -X "$method" -D "$hdr_file" -o "$body_file" "$@" -w '%{http_code}')"
  _headers="$(cat "$hdr_file")"
  _body="$(cat "$body_file")"
  rm -f "$hdr_file" "$body_file"
}

backend_options_hits() {
  # Count OPTIONS requests that reached the echo pod (exclude kube-probe noise).
  if ! command -v oc >/dev/null 2>&1; then
    echo -1
    return
  fi
  oc -n "$NS" logs -l app=http-echo --tail=2000 2>/dev/null \
    | grep -c '"method":"OPTIONS"' || true
}

bold "Testing Gateway API echo + CORS"
echo "  URL:    ${BASE_URL}"
echo "  Origin: ${ORIGIN}"
echo

bold "1) GET /"
do_curl GET "${BASE_URL}/" -H "Origin: ${ORIGIN}"
assert_status "GET /" "200" "$_code"
assert_body_contains "GET body has hostname" "$_body" "\"hostname\":\"${HOST}\""
assert_header "GET CORS" "$_headers" "Access-Control-Allow-Origin" "*"
assert_header "GET CORS" "$_headers" "Access-Control-Allow-Methods" \
  "GET, POST, PUT, PATCH, DELETE, OPTIONS, HEAD"
echo

bold "2) OPTIONS / (CORS preflight — gateway only, no backend)"
options_before="$(backend_options_hits)"
do_curl OPTIONS "${BASE_URL}/" \
  -H "Origin: ${ORIGIN}" \
  -H "Access-Control-Request-Method: GET" \
  -H "Access-Control-Request-Headers: X-Demo,Authorization"
# Brief pause so any accidental backend log line would be flushed
sleep 1
options_after="$(backend_options_hits)"

assert_status "OPTIONS /" "204" "$_code"
assert_body_empty "OPTIONS does not return backend body" "$_body"
assert_header "OPTIONS CORS" "$_headers" "Access-Control-Allow-Origin" "*"
assert_header "OPTIONS CORS" "$_headers" "Access-Control-Allow-Methods" \
  "GET, POST, PUT, PATCH, DELETE, OPTIONS, HEAD"
assert_header "OPTIONS CORS" "$_headers" "Access-Control-Allow-Headers" \
  "Content-Type, Authorization, X-Requested-With, Accept, Origin, X-Demo"
assert_header "OPTIONS CORS" "$_headers" "Access-Control-Max-Age" "86400"

if [[ "$options_before" -ge 0 ]]; then
  if [[ "$options_after" -eq "$options_before" ]]; then
    green "  PASS  OPTIONS did not reach backend (OPTIONS log hits=${options_after})"
    pass=$((pass + 1))
  else
    red "  FAIL  OPTIONS reached backend (OPTIONS log hits ${options_before} -> ${options_after})"
    fail=$((fail + 1))
  fi
else
  echo "  SKIP  backend log check (oc not available)"
fi
echo

bold "3) GET /hello with Origin + X-Demo"
do_curl GET "${BASE_URL}/hello?from=script" \
  -H "Origin: ${ORIGIN}" \
  -H "X-Demo: gateway-api-cors"
assert_status "GET /hello" "200" "$_code"
assert_header "GET CORS" "$_headers" "Access-Control-Allow-Origin" "*"
assert_body_contains "GET body reflects path" "$_body" '"originalUrl":"/hello?from=script"'
echo

bold "Summary: ${pass} passed, ${fail} failed"
if [[ "$fail" -gt 0 ]]; then
  exit 1
fi
green "All checks passed."
