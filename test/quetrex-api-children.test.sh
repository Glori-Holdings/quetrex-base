#!/usr/bin/env bash
# test/quetrex-api-children.test.sh — EXECUTION contract test for bin/quetrex-api's
# epic-child surface: `create-child`, `add-dep`, `is-unblocked`.
#
# Run: bash test/quetrex-api-children.test.sh
# Fail-first against the pre-fix tool from git history:
#   QX_API_BIN=/path/to/old/quetrex-api bash test/quetrex-api-children.test.sh
#
# THE OPERATOR-VISIBLE DEFECT THIS PINS DOWN. "Epics have never worked correctly
# — it just created a new task instead of a sub task." Every child the epic
# decomposition created landed on the board as a TOP-LEVEL card: no parent
# badge, no `CODE-N.C` identifier, and therefore no way for the dispatcher or
# /quetrex:merge to recognize it as a child. Tasks have no DELETE (405), so each
# one is permanent junk on the board.
#
# The pre-fix `qx_create_child` did:
#     JSON.stringify({ parentTaskId: $1, projectCode, title, description })
# and POSTed it blind — no validation of `$1`, no resolution, no check of what
# came back. Two distinct ways that silently produces a top-level task, BOTH
# reproduced here by execution against a fixture server that implements the real
# kanban's semantics (src/app/api/tasks/route.ts):
#
#   (1) EMPTY/BLANK parent argument. `parentTaskId: ""` passes the server's
#       `z.string().nullish()` and then fails the route's `if (data.parentTaskId)`
#       truthiness test — so the server takes the top-level branch and answers
#       201 CREATED. The client printed the new top-level identifier and exited
#       0. Indistinguishable from success. (Tests C, D.)
#   (2) A server that does NOT resolve a human identifier in the request BODY.
#       The live server does (`resolveTaskRef`, quetrex-kanban 102b907), but the
#       client must not depend on it: the human id `QDM-2` is not a UUID, and
#       posting it raw is a bet on a server-side convenience. (Test B.)
#
# So the fix is three things, and each is asserted by execution here, never by
# grep: resolve the parent to its UUID with a GET BEFORE creating anything;
# refuse to POST at all when the parent argument is empty/blank/unknown/itself a
# child; and VERIFY the created record really came back linked (parentTaskId set
# to that UUID and childNumber non-null) before printing an identifier.
#
# CROSS-OWNER CONTRACT asserted here (consumed by /quetrex:merge and the epic
# dispatch tick): `create-child` prints the child's human identifier `CODE-N.C`
# on stdout — one line, nothing else — and prints NOTHING on stdout on any
# failure path.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
API_BIN="${QX_API_BIN:-$REPO_ROOT/bin/quetrex-api}"

if [ ! -f "$API_BIN" ]; then
  echo "FAIL: quetrex-api not found at $API_BIN"
  exit 1
fi
if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not installed — this suite needs node for the fixture HTTP server"
  exit 0
fi

FAIL=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'NOT OK - %s\n' "$1"; FAIL=1; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/quetrex-api-children.XXXXXX")"
SRV_PID=""
# shellcheck disable=SC2329  # invoked indirectly, by the trap below
cleanup() {
  [ -n "$SRV_PID" ] && kill "$SRV_PID" >/dev/null 2>&1
  rm -rf "$TMPROOT"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# FIXTURE SERVER — a faithful miniature of the real kanban task API.
#
# It is NOT a rubber stamp: it keeps a real task store and reproduces the
# server's actual linkage rules, transcribed from quetrex-kanban:
#   - src/lib/task-ref.ts  IDENTIFIER_RE = /^([A-Za-z][A-Za-z0-9]*)-(\d+)(?:\.(\d+))?$/
#   - src/lib/dto.ts       childIdent()  = `CODE-N` or `CODE-N.C`
#   - src/lib/dto.ts       DONE_FOR_UNBLOCKING = merged | deployed | complete
#   - src/app/api/tasks/route.ts  `if (data.parentTaskId)` — a FALSY parent
#     (missing, null, or the empty string) silently takes the top-level branch
#     and still answers 201. That truthiness test is the defect's amplifier and
#     is reproduced exactly.
#
# Every request is appended to the log BEFORE any response decision, so a test
# can assert what actually reached the server (and what was therefore written)
# independent of what the client observed. "Refused to POST" is proven by a
# request count, never by an error message.
#
# MODE (re-read from a file per request, so one server serves every scenario):
#   modern     — the live server: resolves a human identifier in the URL AND in
#                the body's parentTaskId / dependsOnTaskId.
#   uuidonly   — resolves a human identifier in the URL only; a non-UUID body
#                parentTaskId is not resolved and is therefore falsy-equivalent
#                -> creates a TOP-LEVEL task, 201. The audit's hypothesis, and
#                the state of the API before quetrex-kanban 102b907.
#   sabotage   — accepts everything but always drops the parent link (creates a
#                top-level task even for a valid UUID parent). Proves the client
#                VERIFIES the response instead of trusting the 201.
#   noflag     — modern, but omits `isBlocked` from serialized tasks, forcing
#                is-unblocked down its dependency-status fallback path.
#   error500   — every request answers 500.
# ---------------------------------------------------------------------------
cat > "$TMPROOT/fixture-server.js" <<'EOF'
const http = require("http");
const fs = require("fs");
const crypto = require("crypto");
const modeFile = process.argv[2];
const logFile = process.argv[3];

const CODE = "QDM";
const IDENTIFIER_RE = /^([A-Za-z][A-Za-z0-9]*)-(\d+)(?:\.(\d+))?$/;
const UUID_RE = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
const DONE_FOR_UNBLOCKING = new Set(["merged", "deployed", "complete"]);

// Deterministic seed UUIDs so assertions can name them.
const U = (n) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;

/** @type {Array<object>} */
let tasks = [];
function reset() {
  tasks = [
    { id: U(2), code: CODE, number: 2, childNumber: null, parentTaskId: null,
      title: "epic", status: "in_progress", deps: [] },
    { id: U(3), code: CODE, number: 3, childNumber: null, parentTaskId: null,
      title: "another epic", status: "backlog", deps: [] },
    // An existing CHILD — the grandchild guard's target.
    { id: U(31), code: CODE, number: 3, childNumber: 1, parentTaskId: U(3),
      title: "existing child", status: "backlog", deps: [] },
    // Readiness fixtures for is-unblocked.
    { id: U(10), code: CODE, number: 10, childNumber: null, parentTaskId: null,
      title: "no deps", status: "backlog", deps: [] },
    { id: U(11), code: CODE, number: 11, childNumber: null, parentTaskId: null,
      title: "deps all done", status: "backlog", deps: [U(20), U(21), U(22)] },
    { id: U(12), code: CODE, number: 12, childNumber: null, parentTaskId: null,
      title: "one dep in review", status: "backlog", deps: [U(20), U(23)] },
    { id: U(20), code: CODE, number: 20, childNumber: null, parentTaskId: null,
      title: "merged dep", status: "merged", deps: [] },
    { id: U(21), code: CODE, number: 21, childNumber: null, parentTaskId: null,
      title: "deployed dep", status: "deployed", deps: [] },
    { id: U(22), code: CODE, number: 22, childNumber: null, parentTaskId: null,
      title: "complete dep", status: "complete", deps: [] },
    { id: U(23), code: CODE, number: 23, childNumber: null, parentTaskId: null,
      title: "in review dep", status: "in_review", deps: [] },
  ];
}
reset();

const mode = () => {
  try { return fs.readFileSync(modeFile, "utf8").trim(); } catch { return "modern"; }
};

function byId(id) { return tasks.find((t) => t.id === id); }

function resolveRef(ref) {
  if (typeof ref !== "string" || ref.trim() === "") return null;
  const r = ref.trim();
  if (UUID_RE.test(r)) return byId(r) || null;
  const m = IDENTIFIER_RE.exec(r);
  if (!m) return null;
  if (m[1].toUpperCase() !== CODE) return null;
  const number = Number(m[2]);
  const childNumber = m[3] != null ? Number(m[3]) : null;
  return tasks.find((t) => t.number === number && t.childNumber === childNumber) || null;
}

function ident(t) {
  return t.childNumber == null ? `${t.code}-${t.number}` : `${t.code}-${t.number}.${t.childNumber}`;
}

function serialize(t) {
  const deps = t.deps.map((d) => {
    const dt = byId(d);
    return { id: d, identifier: dt ? ident(dt) : d, status: dt ? dt.status : "backlog" };
  });
  const out = {
    id: t.id,
    identifier: ident(t),
    number: t.number,
    projectCode: t.code,
    title: t.title,
    status: t.status,
    parentTaskId: t.parentTaskId,
    parentIdentifier: t.parentTaskId ? `${t.code}-${t.number}` : null,
    childNumber: t.childNumber,
    dependencies: deps,
    isBlocked: deps.some((d) => !DONE_FOR_UNBLOCKING.has(d.status)),
  };
  if (mode() === "noflag") delete out.isBlocked;
  return out;
}

const server = http.createServer((req, res) => {
  const chunks = [];
  req.on("data", (c) => chunks.push(c));
  req.on("end", () => {
    const raw = Buffer.concat(chunks).toString("utf8");
    fs.appendFileSync(logFile, JSON.stringify({ method: req.method, url: req.url, body: raw }) + "\n");

    const m = mode();
    const json = (status, obj) => {
      res.statusCode = status;
      res.setHeader("Content-Type", "application/json");
      res.end(JSON.stringify(obj));
    };

    if (m === "error500") return json(500, { error: "synthetic" });

    // Test-only control plane: reset the store between scenarios.
    if (req.method === "POST" && req.url === "/__reset") { reset(); return json(200, { ok: true }); }

    let body = null;
    if (raw) { try { body = JSON.parse(raw); } catch { return json(400, { error: "bad json" }); } }

    const url = decodeURIComponent(req.url.split("?")[0]);

    // POST /api/tasks
    if (req.method === "POST" && url === "/api/tasks") {
      if (!body || typeof body.title !== "string" || body.title.trim() === "") {
        return json(400, { error: "title required" });
      }
      // The real route: `if (data.parentTaskId)` — falsy means TOP-LEVEL, 201.
      let parent = null;
      if (body.parentTaskId) {
        if (m === "uuidonly" && !UUID_RE.test(String(body.parentTaskId))) {
          parent = null; // no body-ref resolution: silently top-level
        } else {
          parent = resolveRef(String(body.parentTaskId));
          if (!parent) return json(404, { error: "parent not found" });
        }
      }
      if (m === "sabotage") parent = null;

      let number, childNumber;
      if (parent) {
        number = parent.number;
        childNumber = Math.max(0, ...tasks.filter((t) => t.parentTaskId === parent.id)
          .map((t) => t.childNumber || 0)) + 1;
      } else {
        number = Math.max(0, ...tasks.map((t) => t.number)) + 1;
        childNumber = null;
      }
      const t = {
        id: crypto.randomUUID(), code: CODE, number, childNumber,
        parentTaskId: parent ? parent.id : null,
        title: body.title, status: "backlog", deps: [],
      };
      tasks.push(t);
      return json(201, serialize(t));
    }

    // POST /api/tasks/:ref/dependencies
    let mm = /^\/api\/tasks\/(.+)\/dependencies$/.exec(url);
    if (req.method === "POST" && mm) {
      const t = m === "uuidonly" && !UUID_RE.test(mm[1]) ? null : resolveRef(mm[1]);
      if (!t) return json(404, { error: "not found" });
      const depRef = body && body.dependsOnTaskId;
      const dep = m === "uuidonly" && !UUID_RE.test(String(depRef || "")) ? null : resolveRef(String(depRef || ""));
      if (!dep) return json(400, { error: "dependency_not_found" });
      if (dep.id === t.id) return json(400, { error: "cycle_detected" });
      if (!t.deps.includes(dep.id)) t.deps.push(dep.id);
      return json(201, serialize(t));
    }

    // GET /api/tasks/:ref/children
    mm = /^\/api\/tasks\/(.+)\/children$/.exec(url);
    if (req.method === "GET" && mm) {
      const t = resolveRef(mm[1]);
      if (!t) return json(404, { error: "not found" });
      return json(200, tasks.filter((c) => c.parentTaskId === t.id).map(serialize));
    }

    // GET /api/tasks/:ref
    mm = /^\/api\/tasks\/(.+)$/.exec(url);
    if (req.method === "GET" && mm) {
      const t = resolveRef(mm[1]);
      if (!t) return json(404, { error: "not found" });
      return json(200, serialize(t));
    }

    return json(404, { error: "no route" });
  });
});
server.listen(0, "127.0.0.1", () => {
  process.stdout.write("PORT=" + server.address().port + "\n");
});
EOF

MODEFILE="$TMPROOT/mode.txt"
LOGFILE="$TMPROOT/requests.jsonl"
printf 'modern\n' > "$MODEFILE"
: > "$LOGFILE"

node "$TMPROOT/fixture-server.js" "$MODEFILE" "$LOGFILE" > "$TMPROOT/server.out" 2>&1 &
SRV_PID=$!
PORT=""
for _ in $(seq 1 60); do
  PORT="$(sed -n 's/^PORT=//p' "$TMPROOT/server.out" 2>/dev/null | head -1)"
  [ -n "$PORT" ] && break
  sleep 0.1
done
if [ -z "$PORT" ]; then
  echo "NOT OK - fixture server never came up: $(cat "$TMPROOT/server.out" 2>/dev/null)"
  exit 1
fi

set_mode() { printf '%s\n' "$1" > "$MODEFILE"; }

FAKE_TOKEN="FAKE_TOKEN_${RANDOM}${RANDOM}_DO_NOT_LEAK"
FAKEHOME="$TMPROOT/fakehome"
mkdir -p "$FAKEHOME/.quetrex"
node -e '
  const fs = require("fs");
  const [dir, token, port] = process.argv.slice(1);
  fs.writeFileSync(dir + "/.quetrex/auth.json", JSON.stringify({
    kanbanUrl: "http://127.0.0.1:" + port,
    token,
    expiresAt: new Date(Date.now() + 3600_000).toISOString(),
  }));
' "$FAKEHOME" "$FAKE_TOKEN" "$PORT"

# The repo binding create-child needs (resolve_project walks up from $PWD).
WORKDIR="$TMPROOT/repo"
mkdir -p "$WORKDIR/.quetrex"
printf '{"projectCode":"QDM","kanbanUrl":"http://127.0.0.1:%s"}\n' "$PORT" > "$WORKDIR/.quetrex/project.json"

# reset_server — wipe the task store AND the request log between scenarios, so a
# request count is always "requests this scenario made", never a running total.
reset_server() {
  ( cd "$WORKDIR" && HOME="$FAKEHOME" "$API_BIN" POST /__reset '{}' >/dev/null 2>&1 )
  : > "$LOGFILE"
}

# run_api <args...> -> sets OUT (stdout only), ERR (stderr only), CODE
run_api() {
  local outf="$TMPROOT/out.$$" errf="$TMPROOT/err.$$"
  ( cd "$WORKDIR" && HOME="$FAKEHOME" "$API_BIN" "$@" ) >"$outf" 2>"$errf"
  CODE=$?
  OUT="$(cat "$outf")"
  ERR="$(cat "$errf")"
  rm -f "$outf" "$errf"
}

# req_count -> how many requests actually reached the server this scenario.
# NOTE: `grep -c ''` on an EMPTY file prints 0 and exits 1, so a `|| echo 0`
# fallback would print 0 twice ("0\n0") and every numeric comparison against it
# would error out rather than assert. Capture, then default.
req_count() {
  local n
  n="$(grep -c '' "$LOGFILE" 2>/dev/null)"
  printf '%s' "${n:-0}"
}

# post_bodies <path-suffix-regex> -> the body of each POST whose url matches
posts_to() {
  node -e '
    const fs = require("fs");
    const [log, re] = process.argv.slice(1);
    const rx = new RegExp(re);
    for (const l of fs.readFileSync(log, "utf8").split("\n").filter(Boolean)) {
      const r = JSON.parse(l);
      if (r.method === "POST" && rx.test(r.url)) console.log(JSON.stringify({ url: r.url, body: r.body }));
    }
  ' "$LOGFILE" "$1"
}

UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
PARENT_UUID="00000000-0000-4000-8000-000000000002"

# =============================================================================
# TEST A — create-child establishes a REAL parent link: the parent's human id
# is RESOLVED to a UUID (via a GET) and the UUID is what gets posted.
# =============================================================================
set_mode modern
reset_server
run_api create-child QDM-2 "child one" "does a thing"

if [ "$CODE" -eq 0 ]; then
  pass "A1: create-child against a valid epic exits 0"
else
  fail "A1: expected exit 0, got $CODE (stderr: [$ERR])"
fi

A_BODY="$(posts_to '^/api/tasks$' | head -1)"
A_PARENT="$(node -e '
  const l = process.argv[1];
  if (!l) process.exit(1);
  const b = JSON.parse(JSON.parse(l).body || "{}");
  process.stdout.write(String(b.parentTaskId == null ? "" : b.parentTaskId));
' "$A_BODY" 2>/dev/null)"

if [ "$A_PARENT" = "QDM-2" ]; then
  fail "A2: the POST body carried the parent's HUMAN id raw (parentTaskId=\"QDM-2\") — no UUID resolution happened"
elif printf '%s' "$A_PARENT" | grep -Eq "$UUID_RE"; then
  pass "A2: the POST body carries a UUID parentTaskId (not the human id)"
else
  fail "A2: expected a UUID parentTaskId in the POST body, got [$A_PARENT] (body: $A_BODY)"
fi

if [ "$A_PARENT" = "$PARENT_UUID" ]; then
  pass "A3: the posted UUID is the UUID of the task the human id QDM-2 names"
else
  fail "A3: expected parentTaskId=$PARENT_UUID, got [$A_PARENT]"
fi

if node -e '
  const fs = require("fs");
  const lines = fs.readFileSync(process.argv[1], "utf8").split("\n").filter(Boolean).map(JSON.parse);
  const g = lines.findIndex((r) => r.method === "GET" && /^\/api\/tasks\/QDM-2$/.test(decodeURIComponent(r.url)));
  const p = lines.findIndex((r) => r.method === "POST" && r.url === "/api/tasks");
  process.exit(g >= 0 && p >= 0 && g < p ? 0 : 1);
' "$LOGFILE"; then
  pass "A4: the parent is GET-resolved BEFORE anything is created (lookup precedes the POST)"
else
  fail "A4: expected a GET /api/tasks/QDM-2 before the POST /api/tasks; log: $(cat "$LOGFILE")"
fi

if [ "$OUT" = "QDM-2.1" ]; then
  pass "A5: stdout is exactly the child's human identifier CODE-N.C (QDM-2.1)"
else
  fail "A5: expected stdout 'QDM-2.1', got [$OUT]"
fi

if [ "$(printf '%s' "$OUT" | grep -c '')" -eq 1 ]; then
  pass "A6: stdout is a single line (safe for CHILD_ID=\"\$(quetrex-api create-child ...)\")"
else
  fail "A6: expected exactly one line of stdout, got: [$OUT]"
fi

# The board itself, not the client's word for it.
CHILDREN="$( cd "$WORKDIR" && HOME="$FAKEHOME" "$API_BIN" GET /api/tasks/QDM-2/children 2>/dev/null )"
if node -e '
  const a = JSON.parse(process.argv[1] || "[]");
  process.exit(a.length === 1 && a[0].parentTaskId === process.argv[2]
    && a[0].childNumber === 1 && a[0].identifier === "QDM-2.1" ? 0 : 1);
' "$CHILDREN" "$PARENT_UUID"; then
  pass "A7: the board really holds ONE child of QDM-2, linked by UUID, identified QDM-2.1"
else
  fail "A7: the created task is not a linked child on the board: $CHILDREN"
fi

# =============================================================================
# TEST B — the audit's hypothesis, executed: a server that does NOT resolve a
# human identifier in the request BODY. The client must not depend on that
# convenience; posting the human id raw silently yields a TOP-LEVEL task.
# =============================================================================
set_mode uuidonly
reset_server
run_api create-child QDM-2 "child under a uuid-only server" "d"

if [ "$CODE" -eq 0 ]; then
  pass "B1: create-child succeeds against a server that only accepts a UUID parent"
else
  fail "B1: expected exit 0 against a uuid-only server, got $CODE (stderr: [$ERR])"
fi

set_mode modern   # read the store back with full ref resolution
CHILDREN="$( cd "$WORKDIR" && HOME="$FAKEHOME" "$API_BIN" GET /api/tasks/QDM-2/children 2>/dev/null )"
if node -e '
  const a = JSON.parse(process.argv[1] || "[]");
  process.exit(a.length === 1 && a[0].identifier === "QDM-2.1" ? 0 : 1);
' "$CHILDREN"; then
  pass "B2: a real child exists even though the server never resolves a body identifier (the exact way children became top-level cards)"
else
  fail "B2: expected one linked child QDM-2.1, got: $CHILDREN"
fi

# =============================================================================
# TEST C — the operator's reported symptom: an EMPTY parent argument. The
# server's `if (data.parentTaskId)` makes "" fall through to the top-level
# branch and answer 201, so this can only be caught client-side. Nothing may be
# POSTed at all — tasks have no DELETE, so a junk card is permanent.
# =============================================================================
set_mode modern
reset_server
run_api create-child "" "orphan child" "d"

if [ "$CODE" -ne 0 ]; then
  pass "C1: create-child with an empty epic id fails"
else
  fail "C1: expected non-zero exit for an empty epic id, got 0 (stdout: [$OUT])"
fi
if [ "$(req_count)" -eq 0 ]; then
  pass "C2: an empty epic id issues ZERO requests — no undeletable top-level task is created"
else
  fail "C2: expected 0 requests, got $(req_count): $(cat "$LOGFILE")"
fi
if [ -z "$OUT" ]; then
  pass "C3: nothing is printed on stdout on the empty-parent failure path"
else
  fail "C3: expected empty stdout, got [$OUT]"
fi

# Blank (whitespace-only) is the same defect wearing a disguise.
reset_server
run_api create-child "   " "orphan child" "d"
if [ "$CODE" -ne 0 ] && [ "$(req_count)" -eq 0 ]; then
  pass "C4: a whitespace-only epic id is rejected too, with zero requests"
else
  fail "C4: whitespace-only epic id: exit $CODE, $(req_count) request(s)"
fi

# =============================================================================
# TEST D — a missing title must not create anything either.
# =============================================================================
reset_server
run_api create-child QDM-2 "" "d"
if [ "$CODE" -ne 0 ] && [ "$(posts_to '^/api/tasks$' | grep -c '')" -eq 0 ]; then
  pass "D1: an empty child title fails and POSTs nothing"
else
  fail "D1: empty title: exit $CODE, posts: $(posts_to '^/api/tasks$')"
fi

# =============================================================================
# TEST E — an UNKNOWN parent must fail before creating anything. (Pre-fix this
# reached the server, which 404s — but only because the live server resolves
# body refs; the client never checked.)
# =============================================================================
reset_server
run_api create-child QDM-99 "child of nothing" "d"
if [ "$CODE" -ne 0 ]; then
  pass "E1: an unknown parent identifier fails"
else
  fail "E1: expected non-zero exit for an unknown parent, got 0 (stdout: [$OUT])"
fi
if [ "$(posts_to '^/api/tasks$' | grep -c '')" -eq 0 ]; then
  pass "E2: an unknown parent creates nothing (zero POSTs to /api/tasks)"
else
  fail "E2: expected zero POSTs, got: $(posts_to '^/api/tasks$')"
fi

# =============================================================================
# TEST F — one level only, no grandchildren. QDM-3.1 is already a child; making
# a child OF it must be refused client-side (the server would happily do it).
# =============================================================================
reset_server
run_api create-child QDM-3.1 "grandchild" "d"
if [ "$CODE" -ne 0 ]; then
  pass "F1: creating a child of a child (QDM-3.1) is refused"
else
  fail "F1: expected non-zero exit for a grandchild, got 0 (stdout: [$OUT])"
fi
if [ "$(posts_to '^/api/tasks$' | grep -c '')" -eq 0 ]; then
  pass "F2: the grandchild refusal happens BEFORE any create (zero POSTs)"
else
  fail "F2: a grandchild was actually created: $(posts_to '^/api/tasks$')"
fi

# =============================================================================
# TEST G — trust nothing: if the server answers 201 with a task that is NOT
# linked (the precise shape of the operator's bug report), create-child must
# fail loudly and must NOT print an identifier as if it had succeeded. The
# operator has to learn a junk card exists, because it cannot be deleted.
# =============================================================================
set_mode sabotage
reset_server
run_api create-child QDM-2 "child that comes back unlinked" "d"
if [ "$CODE" -ne 0 ]; then
  pass "G1: a 201 that comes back as a TOP-LEVEL task is treated as a failure, not a success"
else
  fail "G1: expected non-zero exit when the created task has no parent link, got 0 (stdout: [$OUT])"
fi
if [ -z "$OUT" ]; then
  pass "G2: no identifier is printed on stdout when the link was not established"
else
  fail "G2: expected empty stdout, got [$OUT] — a caller would store this as CHILD_ID"
fi
if printf '%s' "$ERR" | grep -q 'QDM-'; then
  pass "G3: the error names the task that WAS created, so the operator can reconcile the board"
else
  fail "G3: expected the created identifier in stderr, got: [$ERR]"
fi
set_mode modern

# =============================================================================
# TEST H — add-dep is the same UUID-vs-human-id class. Both endpoints of the
# edge must be resolved, and an empty argument must never reach the server.
# =============================================================================
reset_server
run_api add-dep QDM-12 QDM-11
if [ "$CODE" -eq 0 ]; then
  pass "H1: add-dep with two human identifiers exits 0"
else
  fail "H1: expected exit 0, got $CODE (stderr: [$ERR])"
fi
DEP_POST="$(posts_to '/dependencies$' | head -1)"
if node -e '
  const l = process.argv[1];
  if (!l) process.exit(1);
  const r = JSON.parse(l);
  const b = JSON.parse(r.body || "{}");
  const U = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
  const seg = decodeURIComponent(r.url).replace(/^\/api\/tasks\//, "").replace(/\/dependencies$/, "");
  process.exit(U.test(String(b.dependsOnTaskId || "")) && U.test(seg) ? 0 : 1);
' "$DEP_POST"; then
  pass "H2: add-dep resolves BOTH ends to UUIDs (uuid in the path, uuid in dependsOnTaskId)"
else
  fail "H2: expected UUIDs on both ends of the dependency POST, got: $DEP_POST"
fi

# The edge really landed.
DEPT="$( cd "$WORKDIR" && HOME="$FAKEHOME" "$API_BIN" GET /api/tasks/QDM-12 2>/dev/null )"
if node -e '
  const o = JSON.parse(process.argv[1] || "{}");
  process.exit((o.dependencies || []).some((d) => d.identifier === "QDM-11") ? 0 : 1);
' "$DEPT"; then
  pass "H3: the dependency edge QDM-12 -> QDM-11 is really recorded"
else
  fail "H3: expected QDM-11 among QDM-12's dependencies, got: $DEPT"
fi

reset_server
run_api add-dep "" QDM-11
if [ "$CODE" -ne 0 ] && [ "$(req_count)" -eq 0 ]; then
  pass "H4: add-dep with an empty task id fails with zero requests"
else
  fail "H4: empty task id: exit $CODE, $(req_count) request(s)"
fi
reset_server
run_api add-dep QDM-12 ""
if [ "$CODE" -ne 0 ] && [ "$(req_count)" -eq 0 ]; then
  pass "H5: add-dep with an empty dependency id fails with zero requests"
else
  fail "H5: empty dependency id: exit $CODE, $(req_count) request(s)"
fi

# =============================================================================
# TEST I — is-unblocked's DONE set must equal the server's DONE_FOR_UNBLOCKING
# ({merged, deployed, complete} — src/lib/dto.ts). Asserted twice: once with the
# server's isBlocked flag present, once with it absent (fallback path).
# =============================================================================
for MODE in modern noflag; do
  set_mode "$MODE"
  LABEL="$([ "$MODE" = noflag ] && echo "status fallback" || echo "isBlocked flag")"

  reset_server
  run_api is-unblocked QDM-10
  if [ "$CODE" -eq 0 ]; then
    pass "I1($LABEL): a task with no dependencies is unblocked (exit 0)"
  else
    fail "I1($LABEL): expected exit 0, got $CODE (stderr: [$ERR])"
  fi

  reset_server
  run_api is-unblocked QDM-11
  if [ "$CODE" -eq 0 ]; then
    pass "I2($LABEL): merged + deployed + complete dependencies all count as done (exit 0)"
  else
    fail "I2($LABEL): expected exit 0, got $CODE (stderr: [$ERR])"
  fi

  reset_server
  run_api is-unblocked QDM-12
  if [ "$CODE" -eq 1 ]; then
    pass "I3($LABEL): a dependency at in_review still blocks (exit 1)"
  else
    fail "I3($LABEL): expected exit 1, got $CODE (stderr: [$ERR])"
  fi
done
set_mode modern

# =============================================================================
# TEST J — readiness must never be GUESSED. An API failure is "undetermined",
# not "ready": it must not exit 0, and it must be distinguishable from a real
# "blocked" so a tick can tell a stalled board from a busy one.
# CONTRACT: 0 = ready, 1 = blocked, 2 = undetermined. Only 0 may dispatch.
# =============================================================================
set_mode error500
reset_server
run_api is-unblocked QDM-10
if [ "$CODE" -ne 0 ]; then
  pass "J1: is-unblocked never reports ready when the API call fails"
else
  fail "J1: expected non-zero exit on an API failure, got 0"
fi
if [ "$CODE" -eq 2 ]; then
  pass "J2: an API failure exits 2 (undetermined), distinct from 1 (genuinely blocked)"
else
  fail "J2: expected exit 2 for an undetermined readiness, got $CODE"
fi
set_mode modern

reset_server
run_api is-unblocked ""
if [ "$CODE" -ne 0 ] && [ "$(req_count)" -eq 0 ]; then
  pass "J3: is-unblocked with an empty task id fails without calling the API"
else
  fail "J3: empty task id: exit $CODE, $(req_count) request(s)"
fi

# =============================================================================
# TEST K — the bearer token never leaks through any of these new code paths
# (they add GETs and error messages that did not exist before).
# =============================================================================
set_mode modern
reset_server
run_api create-child QDM-2 "token safety" "d"
ALL="$OUT$ERR"
reset_server
run_api create-child "" "token safety" "d"
ALL="$ALL$OUT$ERR"
set_mode error500
reset_server
run_api create-child QDM-2 "token safety" "d"
ALL="$ALL$OUT$ERR"
set_mode modern
if printf '%s' "$ALL" | grep -qF "$FAKE_TOKEN"; then
  fail "K1: the bearer token leaked into create-child output"
else
  pass "K1: the bearer token never appears in create-child output on any path"
fi

# =============================================================================
# Self-referential completion sentinel — test/run-all.sh requires each unit to
# name ITSELF at the end of a real run, so an all-"ok" count can never be
# credited to a file that merely printed ok-shaped text.
echo
if [ "$FAIL" -eq 0 ]; then
  echo "quetrex-api-children.test.sh: all checks passed"
else
  echo "quetrex-api-children.test.sh: FAILURES above"
fi
exit "$FAIL"
