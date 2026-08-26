#!/usr/bin/env bash
# test/quetrex-api.test.sh — contract test for bin/quetrex-api's error-surfacing
# and retry behavior.
#
# Run: bash test/quetrex-api.test.sh
#
# THE OPERATOR-VISIBLE DEFECT THIS PINS DOWN. /quetrex:task-new's
# POST /api/tasks returned HTTP 500; the identical payload succeeded seconds
# later on retry — a clean transient failure, no partial write, no orphan
# task. But qapi() discarded the response body on any non-2xx and printed
# only "Quetrex API error (HTTP 500)", and task-new.md did
# `RESP="$(quetrex-api POST /api/tasks "$PAYLOAD")" || exit 1` with no retry.
# The operator lost every diagnostic the server sent and had no way to know
# that simply running it again would have worked — indistinguishable from the
# tool being broken. This suite proves the fix:
#   (a) a non-2xx surfaces the server's actual response body, truncated
#   (b) the bearer token NEVER appears in any error output, even if a
#       (misconfigured) server reflects the Authorization header back
#   (c) a transient, retry-eligible failure retries and then succeeds,
#       announcing each retry, for BOTH an idempotent method (GET) and a
#       POST failing with a code that is safe to retry (503)
#   (d) a non-retryable failure (a generic 500 on a POST, which COULD mean a
#       write already committed) does NOT retry — proven by request count,
#       not just by the outcome, so a retry that silently fires and happens
#       to succeed can never pass as "did not retry"
#   (e) the retry cap (3 total attempts) is honored — no more, no fewer
#
# The suite is parameterized the same way test/verify-gate.test.sh is, so a
# fail-first proof can be run against the PRE-FIX tool from git history:
#   QX_API_BIN=/path/to/old/quetrex-api bash test/quetrex-api.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
API_BIN="${QX_API_BIN:-$REPO_ROOT/plugins/quetrex-setup/bin/quetrex-api}"

if [ ! -f "$API_BIN" ]; then
  echo "FAIL: quetrex-api not found at $API_BIN"
  exit 1
fi
if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not installed — this suite needs node for the mock HTTP server"
  exit 0
fi

FAIL=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'NOT OK - %s\n' "$1"; FAIL=1; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/quetrex-api-test.XXXXXX")"
MOCK_PID=""
cleanup() {
  [ -n "$MOCK_PID" ] && kill "$MOCK_PID" >/dev/null 2>&1
  rm -rf "$TMPROOT"
}
trap cleanup EXIT

# --- mock HTTP server --------------------------------------------------------
# Pops one status code per request off a sequence file (one per line; once
# exhausted, keeps returning 500). Logs every request received (method, path,
# body, Authorization header) as one JSON line per request BEFORE acting on
# it — i.e. logging stands in for "the write was committed" — so a test can
# assert exactly how many requests actually reached (and were "written" by)
# the server, independent of what the client ultimately observed. That is the
# only way to prove a retry did or did not fire, and the only way to prove a
# retry did or did not create a server-side duplicate.
# A sequence entry of "DROP" instead of a status code logs the request (the
# "write" happens) and then destroys the raw socket with NO response bytes
# sent at all — reproducing the lost-response failure mode (curl exit 52,
# "empty reply from server") where a write can be fully committed server-side
# even though the client sees a connection-level failure.
# A sequence entry of "REDIRECT:<url>" logs the request (the "write" happens)
# and responds 307 with a Location header pointing at <url> — used to prove
# curl is NOT reading the operator's ~/.curlrc (a `location` line there would
# make curl silently follow the redirect to an unreachable target, hiding
# that the ORIGINAL write already landed behind a curl exit 7 on the
# follow-up hop).
# --reflect-auth echoes the Authorization header value into the error body,
# simulating a misbehaving server, to prove the client-side scrub is real and
# not just "the token never happened to appear."
cat > "$TMPROOT/mock-server.js" <<'EOF'
const http = require("http");
const fs = require("fs");
const port = parseInt(process.argv[2], 10);
const seqFile = process.argv[3];
const logFile = process.argv[4];
const reflectAuth = process.argv[5] === "reflect-auth";

const server = http.createServer((req, res) => {
  const chunks = [];
  req.on("data", (c) => chunks.push(c));
  req.on("end", () => {
    const body = Buffer.concat(chunks).toString("utf8");
    const auth = req.headers["authorization"] || "";
    // The log write happens BEFORE any response decision below — it stands
    // in for the server-side write being committed, regardless of whether a
    // response ever reaches the client.
    fs.appendFileSync(logFile, JSON.stringify({ method: req.method, url: req.url, body, auth }) + "\n");

    let seq = [];
    try { seq = fs.readFileSync(seqFile, "utf8").split("\n").filter(Boolean); } catch {}
    let entry = "500";
    if (seq.length > 0) {
      entry = seq[0];
      fs.writeFileSync(seqFile, seq.slice(1).join("\n") + (seq.length > 1 ? "\n" : ""));
    }

    if (entry === "DROP") {
      // Simulate a lost response after a committed write: destroy the raw
      // socket with zero response bytes sent. curl sees this as "empty
      // reply from server" (exit 52), never as a valid HTTP status.
      req.socket.destroy();
      return;
    }

    if (entry.startsWith("REDIRECT:")) {
      // The write above already happened (logged). Respond with a real 3xx
      // so a curl that reads ~/.curlrc's `location` setting would follow it;
      // a curl invoked with -q must NOT follow it and must return this 307
      // to the caller untouched.
      res.statusCode = 307;
      res.setHeader("Location", entry.slice("REDIRECT:".length));
      res.end();
      return;
    }

    const status = parseInt(entry, 10);
    res.statusCode = status;
    res.setHeader("Content-Type", "application/json");
    if (status >= 200 && status < 300) {
      res.end(JSON.stringify({ ok: true, marker: "MOCK_SUCCESS_MARKER" }));
    } else if (reflectAuth) {
      res.end(JSON.stringify({ error: "synthetic failure", debug: { authorizationHeaderReceived: auth } }));
    } else {
      res.end(JSON.stringify({ error: "MOCK_ERROR_BODY_MARKER", status }));
    }
  });
});
server.listen(port, "127.0.0.1", () => { process.stdout.write("READY\n"); });
EOF

PORT=$((20000 + ($$ % 4000)))

start_mock() {  # start_mock <sequence-csv> [reflect-auth]
  local seq_csv="$1" reflect="${2:-}"
  SEQFILE="$TMPROOT/seq-$$-$RANDOM.txt"
  LOGFILE="$TMPROOT/log-$$-$RANDOM.jsonl"
  : > "$LOGFILE"
  printf '%s\n' "$seq_csv" | tr ',' '\n' > "$SEQFILE"
  node "$TMPROOT/mock-server.js" "$PORT" "$SEQFILE" "$LOGFILE" ${reflect:+reflect-auth} > "$TMPROOT/mock-ready.log" 2>&1 &
  MOCK_PID=$!
  # Wait for the server to report ready rather than a fixed sleep.
  for _ in $(seq 1 50); do
    grep -q READY "$TMPROOT/mock-ready.log" 2>/dev/null && break
    sleep 0.1
  done
}

stop_mock() {
  [ -n "$MOCK_PID" ] && kill "$MOCK_PID" >/dev/null 2>&1
  wait "$MOCK_PID" 2>/dev/null
  MOCK_PID=""
}

log_line_count() {  # log_line_count -> N requests actually received
  [ -f "$LOGFILE" ] && grep -c '' "$LOGFILE" 2>/dev/null || echo 0
}

# FAKE_TOKEN is unique per run so a match can never be a coincidence.
FAKE_TOKEN="FAKE_TOKEN_${RANDOM}${RANDOM}_DO_NOT_LEAK"

mk_fake_home() {  # mk_fake_home <dir>
  mkdir -p "$1/.quetrex"
  node -e '
    const fs = require("fs");
    const [dir, token, port] = process.argv.slice(1);
    const auth = {
      kanbanUrl: "http://127.0.0.1:" + port,
      token,
      expiresAt: new Date(Date.now() + 3600_000).toISOString()
    };
    fs.writeFileSync(dir + "/.quetrex/auth.json", JSON.stringify(auth));
  ' "$1" "$FAKE_TOKEN" "$PORT"
}

FAKEHOME="$TMPROOT/fakehome"
mk_fake_home "$FAKEHOME"

run_api() {  # run_api <METHOD> <PATH> [BODY] -> sets OUT, CODE
  OUT="$(HOME="$FAKEHOME" "$API_BIN" "$@" 2>&1)"; CODE=$?
}

# =============================================================================
# TEST A — a non-2xx surfaces the server's actual response body.
# =============================================================================
start_mock "500"
run_api POST /api/tasks '{"title":"x"}'
if [ "$CODE" -ne 0 ]; then
  pass "A: a non-2xx POST returns non-zero"
else
  fail "A: expected non-zero exit, got 0 (out: [$OUT])"
fi
if printf '%s' "$OUT" | grep -q 'MOCK_ERROR_BODY_MARKER'; then
  pass "A: the server's actual response body reaches the operator (not a bare status code)"
else
  fail "A: expected the server's response body in the output, got: [$OUT]"
fi
stop_mock

# =============================================================================
# TEST B — the bearer token NEVER appears in error output, even if the server
# reflects the Authorization header back (a misbehaving/debug server).
# =============================================================================
start_mock "500" reflect-auth
run_api POST /api/tasks '{"title":"x"}'
if printf '%s' "$OUT" | grep -qF "$FAKE_TOKEN"; then
  fail "B: the bearer token leaked into error output: [$OUT]"
else
  pass "B: the bearer token never appears in error output, even when the server reflects it"
fi
if printf '%s' "$OUT" | grep -q '\[REDACTED\]'; then
  pass "B: the scrub actually fired (output shows [REDACTED], proving the token was found and removed, not just absent by luck)"
else
  fail "B: expected a [REDACTED] marker proving the scrub ran, got: [$OUT]"
fi
stop_mock

# =============================================================================
# TEST C — a transient, retry-eligible failure retries and then succeeds, for
# an idempotent method (GET) and for a POST failing with a code that IS safe
# to retry (503 — rejected before dispatch, never after a write).
# =============================================================================
start_mock "500,200"
run_api GET /api/tasks/SMA-1
if [ "$CODE" -eq 0 ] && printf '%s' "$OUT" | grep -q 'MOCK_SUCCESS_MARKER'; then
  pass "C(GET): a transient 500 retries and the eventual success reaches the operator"
else
  fail "C(GET): expected exit 0 with the success body after retry, got exit $CODE: [$OUT]"
fi
if printf '%s' "$OUT" | grep -qi 'retrying'; then
  pass "C(GET): the retry is announced, not a silent pause"
else
  fail "C(GET): expected a 'retrying' announcement, got: [$OUT]"
fi
if [ "$(log_line_count)" = "2" ]; then
  pass "C(GET): exactly 2 requests reached the server (1 failure + 1 retry that succeeded)"
else
  fail "C(GET): expected exactly 2 requests, got $(log_line_count)"
fi
stop_mock

start_mock "503,201"
run_api POST /api/tasks '{"title":"x"}'
if [ "$CODE" -eq 0 ] && printf '%s' "$OUT" | grep -q 'MOCK_SUCCESS_MARKER'; then
  pass "C(POST-503): a 503 (rejected before dispatch) retries a POST and the eventual success reaches the operator"
else
  fail "C(POST-503): expected exit 0 with the success body after retry, got exit $CODE: [$OUT]"
fi
if [ "$(log_line_count)" = "2" ]; then
  pass "C(POST-503): exactly 2 requests reached the server"
else
  fail "C(POST-503): expected exactly 2 requests, got $(log_line_count)"
fi
stop_mock

# =============================================================================
# TEST D — a non-retryable failure (generic 500 on a POST, which could mean a
# write already committed server-side) does NOT retry. Proven by REQUEST
# COUNT: the sequence queues a 500 then a 200, so if retry incorrectly fired
# here, the call would silently SUCCEED on the phantom retry — the most
# dangerous possible failure mode (a duplicate, permanently un-deletable
# task). Checking only the outcome could not catch that; checking the request
# count can.
# =============================================================================
start_mock "500,200"
run_api POST /api/tasks '{"title":"x"}'
if [ "$CODE" -ne 0 ]; then
  pass "D: a non-retryable 500 on POST returns non-zero (does not silently succeed off a phantom retry)"
else
  fail "D: expected non-zero exit — a 500 on POST must never retry into a false success (out: [$OUT])"
fi
if [ "$(log_line_count)" = "1" ]; then
  pass "D: exactly 1 request reached the server — no retry was attempted for a non-idempotent-unsafe failure"
else
  fail "D: expected exactly 1 request (no retry), got $(log_line_count) — a POST retried on a plain 500"
fi
stop_mock

# =============================================================================
# TEST F — THE BLOCKING DEFECT THIS SUITE ADDS. A lost response after the
# write was already committed server-side (curl exit 52, "empty reply from
# server" — code normalizes to "000") must NOT retry a POST, because the
# request may have already been fully processed. The pre-fix tool retried
# EVERY code="000" case unconditionally, regardless of method, which turns a
# single logical write into permanent duplicate tasks (there is no
# DELETE /api/tasks). Proven by SERVER-SIDE WRITE COUNT, not just the client's
# exit code — the write is logged before the socket is destroyed, exactly
# like a Fly.io machine restart or an OOM kill after a commit.
# =============================================================================
start_mock "DROP,200"
run_api POST /api/tasks '{"title":"x"}'
if [ "$CODE" -ne 0 ]; then
  pass "F: a lost-response (curl exit 52) POST returns non-zero (does not silently succeed off a phantom retry)"
else
  fail "F: expected non-zero exit — a lost response on POST must never retry into a false success (out: [$OUT])"
fi
if [ "$(log_line_count)" = "1" ]; then
  pass "F: exactly 1 write reached the server — no retry was attempted for a POST whose response was lost"
else
  fail "F: expected exactly 1 server-side write (no retry), got $(log_line_count) — a POST retried after a lost response, creating a duplicate write"
fi
stop_mock

# =============================================================================
# TEST G — the SAME lost-response failure (curl exit 52) IS safe to retry for
# an idempotent method (GET), and the retry succeeds. Proves the fix is a
# method-aware classification, not just "never retry code=000".
# =============================================================================
start_mock "DROP,200"
run_api GET /api/tasks/SMA-1
if [ "$CODE" -eq 0 ] && printf '%s' "$OUT" | grep -q 'MOCK_SUCCESS_MARKER'; then
  pass "G: a lost-response (curl exit 52) GET retries and the eventual success reaches the operator"
else
  fail "G: expected exit 0 with the success body after retry, got exit $CODE: [$OUT]"
fi
if [ "$(log_line_count)" = "2" ]; then
  pass "G: exactly 2 requests reached the server (1 lost response + 1 retry that succeeded)"
else
  fail "G: expected exactly 2 requests, got $(log_line_count)"
fi
stop_mock

# =============================================================================
# TEST H — a connection-level failure that PROVABLY never reached the server
# (curl exit 7, connection refused — nothing is listening) DOES retry a POST.
# This is the other half of the classification: not every code="000" is
# unsafe, only the ones where the request could have been transmitted. No
# server is running at all here, so this is checked via the client's own
# retry announcements, not a write count.
# =============================================================================
REFUSED_PORT=$((PORT + 1))
REFUSEDHOME="$TMPROOT/refusedhome"
mkdir -p "$REFUSEDHOME/.quetrex"
node -e '
  const fs = require("fs");
  const [dir, token, port] = process.argv.slice(1);
  const auth = {
    kanbanUrl: "http://127.0.0.1:" + port,
    token,
    expiresAt: new Date(Date.now() + 3600_000).toISOString()
  };
  fs.writeFileSync(dir + "/.quetrex/auth.json", JSON.stringify(auth));
' "$REFUSEDHOME" "$FAKE_TOKEN" "$REFUSED_PORT"
OUT="$(HOME="$REFUSEDHOME" "$API_BIN" POST /api/tasks '{"title":"x"}' 2>&1)"; CODE=$?
if [ "$CODE" -ne 0 ]; then
  pass "H: connection-refused POST eventually returns non-zero (nothing is listening — never succeeds)"
else
  fail "H: expected non-zero exit against a port nothing is listening on, got 0 (out: [$OUT])"
fi
RETRY_ANNOUNCEMENTS_H="$(printf '%s' "$OUT" | grep -ci 'retrying' || true)"
[ -n "$RETRY_ANNOUNCEMENTS_H" ] || RETRY_ANNOUNCEMENTS_H=0
if [ "$RETRY_ANNOUNCEMENTS_H" = "2" ]; then
  pass "H: connection-refused (curl exit 7) DOES retry a POST — proven never to have reached the server, safe for any method"
else
  fail "H: expected exactly 2 retry announcements for a connection-refused POST, got $RETRY_ANNOUNCEMENTS_H: [$OUT]"
fi

# =============================================================================
# TEST I — THE .curlrc REDIRECT VECTOR. Without -q as curl's FIRST argument,
# curl reads the operator's ~/.curlrc. A `location` line there — an ordinary
# developer setting, "follow redirects" — makes curl silently follow a 3xx
# response: the ORIGINAL request (and its write) is delivered and committed
# to the mock server, then curl's own exit code reflects only the REDIRECT
# TARGET (here, port 1 — always connection-refused, curl exit 7) failing.
# The 6|7 classification (Test H, correctly) treats curl exit 7 as "never
# reached the server, safe to retry ANY method" — but here that is exactly
# backwards, because the ORIGINAL POST already landed before curl ever
# followed the redirect. Without -q, that misclassification retries the
# original POST up to the 3-attempt cap: 3 committed server-side writes for
# 1 logical request, the same shape as the original blocker, through a door
# the 6|7 arm itself declared safe. Proven by WRITE COUNT, exactly like every
# other test above.
# =============================================================================
start_mock "REDIRECT:http://127.0.0.1:1/blocked,REDIRECT:http://127.0.0.1:1/blocked,REDIRECT:http://127.0.0.1:1/blocked"
CURLRCHOME="$TMPROOT/curlrchome"
mk_fake_home "$CURLRCHOME"
printf 'location\n' > "$CURLRCHOME/.curlrc"
OUT="$(HOME="$CURLRCHOME" "$API_BIN" POST /api/tasks '{"title":"x"}' 2>&1)"; CODE=$?
if [ "$CODE" -ne 0 ]; then
  pass "I: a POST behind a .curlrc-redirected connection failure returns non-zero"
else
  fail "I: expected non-zero exit, got 0 (out: [$OUT])"
fi
if [ "$(log_line_count)" = "1" ]; then
  pass "I: exactly 1 server-side write reached the server — -q stopped curl from reading .curlrc and following the redirect into a misclassified retry loop"
else
  fail "I: expected exactly 1 server-side write, got $(log_line_count) — curl read .curlrc and the redirect-then-refused vector retried a POST, creating duplicate writes"
fi
stop_mock

# =============================================================================
# TEST E — the retry cap (3 total attempts) is honored: 4 failures are queued
# for an idempotent GET (which retries every 5xx), but only 3 may ever be
# consumed.
# =============================================================================
start_mock "500,500,500,500"
run_api GET /api/tasks/SMA-1
if [ "$CODE" -ne 0 ]; then
  pass "E: a persistently-failing GET returns non-zero after exhausting the cap"
else
  fail "E: expected non-zero exit after the cap is exhausted, got 0 (out: [$OUT])"
fi
if [ "$(log_line_count)" = "3" ]; then
  pass "E: exactly 3 requests reached the server — the retry cap is honored, not unbounded and not fewer than allowed"
else
  fail "E: expected exactly 3 requests (the retry cap), got $(log_line_count)"
fi
RETRY_ANNOUNCEMENTS="$(printf '%s' "$OUT" | grep -ci 'retrying' || true)"
[ -n "$RETRY_ANNOUNCEMENTS" ] || RETRY_ANNOUNCEMENTS=0
if [ "$RETRY_ANNOUNCEMENTS" = "2" ]; then
  pass "E: exactly 2 retry announcements (attempts 2 and 3 of 3) — the 3rd, final failure is not announced as 'retrying' again"
else
  fail "E: expected exactly 2 retry announcements, got $RETRY_ANNOUNCEMENTS"
fi
stop_mock

# =============================================================================
# SUCCESS-PATH OUTPUT SHAPE IS UNCHANGED — a plain first-try 2xx still prints
# exactly the response body on stdout and nothing else, with no retry
# announcement noise. task-new.md and other commands parse this directly.
# =============================================================================
start_mock "201,200"
OUT_STDOUT_ONLY="$(HOME="$FAKEHOME" "$API_BIN" POST /api/tasks '{"title":"x"}' 2>/dev/null)"; CODE_SHAPE=$?
OUT_STDERR_ONLY="$(HOME="$FAKEHOME" "$API_BIN" GET /api/tasks/SMA-1 2>&1 1>/dev/null)"
if [ "$CODE_SHAPE" -eq 0 ] && printf '%s' "$OUT_STDOUT_ONLY" | grep -q 'MOCK_SUCCESS_MARKER'; then
  pass "SHAPE: a plain first-try 2xx still prints the response body on stdout, exit 0"
else
  fail "SHAPE: expected the success body on stdout with exit 0, got exit $CODE_SHAPE: [$OUT_STDOUT_ONLY]"
fi
if [ -z "$OUT_STDERR_ONLY" ]; then
  pass "SHAPE: a plain first-try 2xx writes nothing to stderr (no retry noise on the happy path)"
else
  fail "SHAPE: expected empty stderr on a first-try success, got: [$OUT_STDERR_ONLY]"
fi
stop_mock

echo
if [ "$FAIL" -eq 0 ]; then
  echo "quetrex-api.test.sh: all checks passed"
else
  echo "quetrex-api.test.sh: FAILURES above"
fi
exit "$FAIL"
