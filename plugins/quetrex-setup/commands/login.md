---
description: Log in to the Quetrex kanban via browser device-flow and store a per-user API token at ~/.quetrex/auth.json. Run once per machine before /quetrex-setup:init. Usage: /quetrex-setup:login [kanbanUrl]
argument-hint: "[kanbanUrl — defaults to https://dash.quetrex.com]"
---

# Quetrex Login

Authenticate this machine to the Quetrex kanban using the browser **device flow**, then
store a per-user API token at `~/.quetrex/auth.json` (mode `600`). This is the only skill
that legitimately handles the raw token — it runs **before** auth exists, so it does **not**
gate on existing auth. It uses raw `curl` for the device flow and writes the token
straight to disk without ever printing it.

**Token safety is the prime directive.** The raw token only ever flows
`curl stdout → pipe → node → file (chmod 600)`. Never `echo`, `cat`, or `printf` the token to
stdout, never put it on argv, never log it. No `set -x`, no `curl -v` anywhere in this skill.

Run the steps below as a **single bash block** so the device code and token stay in-process.

---

## 1. Resolve the base URL

```bash
KANBAN_URL="$(echo "$ARGUMENTS" | tr -d '[:space:]')"
[ -z "$KANBAN_URL" ] && KANBAN_URL="https://dash.quetrex.com"
KANBAN_URL="${KANBAN_URL%/}"   # strip any trailing slash
```

---

## 2. Start the device flow

```bash
START="$(curl -sS -X POST "$KANBAN_URL/api/auth/device/start" -w $'\n%{http_code}')" || {
  echo "Could not reach $KANBAN_URL — check your connection and try again." >&2
  exit 1
}
START_CODE="${START##*$'\n'}"
START_BODY="${START%$'\n'*}"
if [ "${START_CODE#2}" = "$START_CODE" ]; then
  echo "Device-flow start failed (HTTP $START_CODE)." >&2
  exit 1
fi
```

Parse the non-secret fields with `node` (the `deviceCode` is single-use and short-lived, so it
is safe to hold in a shell var — but do **not** print it; only show `USER_CODE` and
`VERIFICATION_URL`):

```bash
# NEVER `read ... < <(...)` here. `read` returns NON-ZERO when the final line
# carries no trailing newline, so a `|| { fatal }` guard fires on SUCCESS — the
# values are in the variables and the command aborts anyway. That defect shipped
# in this command and in /quetrex-setup:update, and it made both fail 100% of the time:
# a new teammate could not even log in. Capture, check, then read fields by line.
DEVICE_FIELDS="$(node -e '
  let s=""; process.stdin.on("data",d=>s+=d).on("end",()=>{
    let o; try{o=JSON.parse(s)}catch{process.exit(1)}
    if(!o.deviceCode||!o.userCode||!o.verificationUrl){process.exit(1)}
    process.stdout.write([
      o.deviceCode, o.userCode, o.verificationUrl,
      String(o.intervalSeconds||5), String(o.expiresInSeconds||600)
    ].join("\n"))
  })' <<<"$START_BODY")" || { echo "Unexpected device-flow response." >&2; exit 1; }
# One field per LINE, picked by line number. NEVER `set -- $DEVICE_FIELDS`:
# zsh does not word-split an unquoted parameter (SH_WORD_SPLIT is off by
# default), so $1 would swallow all five fields and every value after it would
# be empty. Shipped blocks run in the operator's shell — zsh on macOS.
# Arity FIRST: exactly five lines. A value carrying a newline would otherwise
# shift every later field by a slot — a hostile /device/start body could put an
# attacker's URL in VERIFICATION_URL and still pass a per-field non-empty check.
[ "$(printf '%s\n' "$DEVICE_FIELDS" | wc -l | tr -d ' ')" = "5" ] \
  || { echo "Unexpected device-flow response." >&2; exit 1; }
fld() { printf '%s\n' "$DEVICE_FIELDS" | sed -n "${1}p"; }
DEVICE_CODE="$(fld 1)"; USER_CODE="$(fld 2)"; VERIFICATION_URL="$(fld 3)"
INTERVAL="$(fld 4)"; EXPIRES="$(fld 5)"
[ -n "$DEVICE_CODE" ] && [ -n "$USER_CODE" ] && [ -n "$VERIFICATION_URL" ] \
  && [ -n "$INTERVAL" ] && [ -n "$EXPIRES" ] \
  || { echo "Unexpected device-flow response." >&2; exit 1; }
```

---

## 3. Show the code and open the browser

Print the user code and verification URL, then try to open the browser. A failure to open is
**non-fatal** — tell the user to visit the URL manually.

```bash
echo "Approve this login in your browser. Code: $USER_CODE"
echo "Opening $VERIFICATION_URL"
if command -v open >/dev/null 2>&1; then
  open "$VERIFICATION_URL" >/dev/null 2>&1 || true
elif command -v xdg-open >/dev/null 2>&1; then
  xdg-open "$VERIFICATION_URL" >/dev/null 2>&1 || true
else
  echo "Could not open a browser automatically — visit the URL above to approve."
fi
```

---

## 4. Poll for the token and write auth.json token-safely

Poll `/api/auth/device/token` every `$INTERVAL` seconds until a terminal outcome or the
deadline (`now + $EXPIRES`). The poll response body is piped **straight into a `node` parser**
that, on success, writes `~/.quetrex/auth.json` itself and prints **only a non-secret status
word** (`ok` / `pending` / `expired` / `denied` / `error`). The raw token thus flows
curl → pipe → node → file and never touches the shell's stdout or argv.

```bash
mkdir -p "$HOME/.quetrex"
chmod 700 "$HOME/.quetrex"
AUTH_PATH="$HOME/.quetrex/auth.json"

DEADLINE=$(( $(date +%s) + EXPIRES ))
MINUTES=$(( EXPIRES / 60 ))
STATUS="error"

while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  # The token (if any) is consumed by node and written to AUTH_PATH; node prints
  # only a status word. Never echo/cat the poll body.
  STATUS="$(curl -sS -X POST "$KANBAN_URL/api/auth/device/token" \
      -H 'Content-Type: application/json' \
      --data "$(node -e 'process.stdout.write(JSON.stringify({deviceCode:process.argv[1]}))' "$DEVICE_CODE")" \
    | node -e '
      const fs=require("fs");
      const [authPath, kanbanUrl] = process.argv.slice(1);
      let s=""; process.stdin.on("data",d=>s+=d).on("end",()=>{
        let o; try{o=JSON.parse(s)}catch{ process.stdout.write("error"); return; }
        if(o && o.status==="pending"){ process.stdout.write("pending"); return; }
        if(o && o.token){
          const exp = o.expiresAt
            ? new Date(o.expiresAt).toISOString()
            : new Date(Date.now()+90*864e5).toISOString();
          fs.writeFileSync(authPath, JSON.stringify({
            kanbanUrl, token:o.token, expiresAt:exp
          }, null, 2));
          fs.chmodSync(authPath, 0o600);
          process.stdout.write("ok");
          return;
        }
        const e = o && o.error ? String(o.error) : "error";
        process.stdout.write(e==="expired"?"expired":e==="denied"?"denied":"error");
      })' "$AUTH_PATH" "$KANBAN_URL")"

  case "$STATUS" in
    ok)      break ;;
    pending) sleep "$INTERVAL" ;;
    expired) echo "Login code expired — run /quetrex-setup:login again." >&2; exit 1 ;;
    denied)  echo "Login was denied in the browser." >&2; exit 1 ;;
    *)       echo "Login failed — run /quetrex-setup:login again." >&2; exit 1 ;;
  esac
done

if [ "$STATUS" != "ok" ]; then
  echo "Login timed out after $MINUTES minutes — run /quetrex-setup:login again." >&2
  exit 1
fi

chmod 600 "$AUTH_PATH"
```

After this block `~/.quetrex/auth.json` exists at mode `600` with
`{kanbanUrl, token, expiresAt}`, and the token was never printed.

---

## 5. Confirm identity without printing the token

Now that auth exists, use the `quetrex-api` tool (shipped on the plugin's PATH — it injects the
bearer via a `0600` temp config and never echoes it) to fetch the caller's record and report the
email.

```bash
# Confirm auth loaded (suppress the tool's own message so only the login-specific one shows).
quetrex-api kanban-url >/dev/null 2>&1 || { echo "Login saved, but auth could not be loaded — run /quetrex-setup:login again." >&2; exit 1; }

ME="$(quetrex-api GET /api/users/me)" || exit 1   # the CALLER'S OWN record (bound to this token), not a list
EMAIL="$(node -e '
  let s=process.argv[1]; let o; try{o=JSON.parse(s)}catch{process.exit(1)}
  // /api/users/me returns the caller identity object directly ({id,name,email,image}).
  // Never take users[0] of a list — that names whoever is first, not the caller.
  const u = (o && o.user) ? o.user : o;
  if(!u || !u.email){process.exit(1)}
  process.stdout.write(String(u.email))
' "$ME")" || { echo "Login saved, but could not confirm identity."; exit 0; }

echo "Logged in as $EMAIL"
```

If `/api/users/me` returns a non-2xx, `quetrex-api` already printed the correct message — just stop.
If the body parses but has no email, report `Login saved, but could not confirm identity.`
and exit `0` (the token is still valid and on disk).

---

## Error-handling rules

- Never echo/print the bearer token or the success response body. No `set -x`, no `curl -v`.
- Distinguish the outcomes with specific one-line messages: expired, denied, generic failure,
  timeout, and network/unreachable.
- This skill does **not** gate on existing auth — it calls the `quetrex-api` tool only **after**
  writing `auth.json`, for the confirmation step.
- `~/.quetrex` is mode `700`; `~/.quetrex/auth.json` is mode `600`.
