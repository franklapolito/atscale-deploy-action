#!/usr/bin/env bash
# demo1: give Canary a connection of its own for golden SQL, in the pattern swtdev uses ("Snowflake Partner Canary":
# one subgroup, query role data_preview_query_role only, programmatic access token sign-in). Guide:
# docs/canary/golden-sql-engine.md in AtScaleInc/mcp, step 2.
#
#   bash ~/GitHub/atscale-deploy-action/scripts/demo1-canary-golden.sh
#
# What it does:
#   1. Snowflake (profile se-demo-admin, browser sign-in): makes a programmatic access token for the read-only service
#      user CANARY_READER_USER (role CANARY_READER, SELECT on SE_DEMO_LIBRARY only). If a token named DEMO1_CANARY
#      exists it is rotated, and the old one expires at once.
#   2. demo1: asks the engine to sign in with that token WITHOUT saving it (subgroup-test). It stops if that fails.
#   3. demo1: creates the connection "Snowflake Partner Canary" as a copy of "Snowflake Partner" (same host, database
#      SE_DEMO_LIBRARY, warehouse SE_DEMO_FL_SMALL) with that one subgroup. If the connection exists, it only replaces
#      the subgroup's token. "Snowflake Partner" itself is not changed.
# The token goes from Snowflake to the VM on standard input: never printed, never on a command line, never on disk.
# After it: Canary UI -> Settings -> Expected answers (golden SQL) -> Engine data connection = Snowflake Partner Canary.
set -euo pipefail
KEY="${KEY:-$HOME/.ssh/id_rsa}"; HOST="${HOST:-atscale@172.203.218.112}"
URL="${URL:-https://demo.poc.atscale-se-demo.com}"
SRC="${SRC:-Snowflake Partner}"; NEW="${NEW:-Snowflake Partner Canary}"; FROM_SUBGROUP="${FROM_SUBGROUP:-Small Connection}"
SF_PROFILE="${SF_PROFILE:-se-demo-admin}"; SF_USER=CANARY_READER_USER; SF_ROLE=CANARY_READER; PAT_NAME="${PAT_NAME:-DEMO1_CANARY}"

pat() {  # prints the new token secret on stdout, nothing else
  snow sql -c "$SF_PROFILE" --format json -q "$1" 2>/dev/null | python3 -c '
import sys, json
t = sys.stdin.read(); i = t.find("[")
try: rows = json.loads(t[i:])
except Exception: sys.exit(1)
if rows and isinstance(rows[0], list): rows = rows[-1]
for r in rows:
    for k, v in r.items():
        if k.lower() == "token_secret" and v: print(v, end=""); sys.exit(0)
sys.exit(1)'
}
echo "1. Snowflake: token for $SF_USER (a browser sign-in may open)"
TOKEN="$(pat "ALTER USER $SF_USER ADD PROGRAMMATIC ACCESS TOKEN $PAT_NAME ROLE_RESTRICTION = '$SF_ROLE' DAYS_TO_EXPIRY = 365 COMMENT = 'AtScale demo1 Canary golden SQL'" || true)"
if [ -z "$TOKEN" ]; then
  echo "   no new token (one named $PAT_NAME probably exists): rotating it"
  TOKEN="$(pat "ALTER USER $SF_USER ROTATE PROGRAMMATIC ACCESS TOKEN $PAT_NAME EXPIRE_ROTATED_TOKEN_AFTER_HOURS = 0" || true)"
fi
[ -n "$TOKEN" ] || { echo "   could not get a token from Snowflake. Run this to see the error:"; echo "   snow sql -c $SF_PROFILE -q \"SHOW USER PROGRAMMATIC ACCESS TOKENS FOR USER $SF_USER\""; exit 1; }
echo "   got a token (${#TOKEN} characters, not shown)"

{ printf '%s\n' "$TOKEN"; cat <<'REMOTE'
set -euo pipefail
K="sudo microk8s kubectl -n atscale"
CID="$($K get configmap atscale-mcp-server-extra-env -o 'jsonpath={.data.ATSCALE_MCP_KEYCLOAK_CLIENT_ID}' </dev/null)"
export CSEC="$($K get secret atscale-kc-clients -o 'jsonpath={.data.mcp}' </dev/null | base64 -d)"
export CID
python3 - <<'PY'
import os, sys, json, ssl, urllib.request, urllib.parse, urllib.error
URL = os.environ["PUBLIC_URL"]; SRC = os.environ["SRC"]; NEW = os.environ["NEW"]; FROM = os.environ["FROM_SUBGROUP"]
PAT = os.environ["CANARY_PAT"]; ROLE = "data_preview_query_role"; SUB_NAME = "Canary Preview"
ctx = ssl.create_default_context()
def call(method, url, body=None, tok=None, form=False):
    data = None; h = {}
    if body is not None:
        if form: data = urllib.parse.urlencode(body).encode(); h["Content-Type"] = "application/x-www-form-urlencoded"
        else: data = json.dumps(body).encode(); h["Content-Type"] = "application/json"
    if tok: h["Authorization"] = "Bearer " + tok
    try:
        with urllib.request.urlopen(urllib.request.Request(url, data=data, headers=h, method=method), timeout=120, context=ctx) as r:
            t = r.read().decode(); return r.status, (json.loads(t) if t else None)
    except urllib.error.HTTPError as e:
        t = e.read().decode()
        try: return e.code, json.loads(t)
        except Exception: return e.code, {"raw": t[:400]}
def safe(o):  # a response body with anything that could be a credential removed
    s = json.dumps(o)[:600]
    return s.replace(PAT, "[TOKEN]")
st, d = call("POST", URL + "/auth/realms/atscale/protocol/openid-connect/token",
             {"grant_type": "client_credentials", "client_id": os.environ["CID"], "client_secret": os.environ["CSEC"], "scope": "openid"}, form=True)
tok = (d or {}).get("access_token")
if not tok: sys.exit("no service-account token: %s / %s" % ((d or {}).get("error"), (d or {}).get("error_description")))
E = URL + "/engine/connection-groups"
def groups():
    st, d = call("GET", E, tok=tok)
    if st != 200: sys.exit("GET connection-groups -> %s %s" % (st, safe(d)))
    return d["response"]["results"]
def group(gid):
    st, d = call("GET", E + "/connection-group/" + gid, tok=tok)
    if st != 200: sys.exit("GET connection-group -> %s %s" % (st, safe(d)))
    g = d["response"]["results"]
    return g[0] if isinstance(g, list) else g
def subkey(g): return "subgroups" if "subgroups" in g else "connectionSubgroups"
src = [g for g in groups() if g.get("name") == SRC]
if not src: sys.exit("connection %r not found on this box" % SRC)
g = group(src[0]["id"]); sk = subkey(g)
base = [s for s in g[sk] if s.get("name") == FROM] or g[sk]
sub = {k: v for k, v in base[0].items() if k not in ("id", "secretRefs", "username")}
sub["name"] = SUB_NAME; sub["queryRoles"] = [ROLE]
ep = dict(sub.get("extraProperties") or {}); ep["accessType"] = "use_programmatic_access_token"; sub["extraProperties"] = ep
sub["secretProperties"] = {"password": PAT}
print("2. engine sign-in test with the new token (nothing is saved)")
st, d = call("POST", E + "/subgroup-test", sub, tok=tok)
res = safe((d or {}).get("response", d))
print("   subgroup-test -> http %s %s" % (st, res))
if "test_connection_subgroup_success" not in res: sys.exit("   the engine could not sign in to Snowflake with the token. Nothing was created.")
print("3. connection %r" % NEW)
have = [x for x in groups() if x.get("name") == NEW or x.get("connectionId") == NEW]
if have:
    cur = group(have[0]["id"]); prev = [s for s in cur[subkey(cur)] if ROLE in (s.get("queryRoles") or [])]
    if prev:
        st, d = call("PUT", E + "/connection-group/%s/connection-subgroup/%s" % (cur["id"], prev[0]["id"]), sub, tok=tok)
        print("   exists; replaced the preview subgroup's token -> http %s %s" % (st, safe(d)))
    else:
        st, d = call("POST", E + "/connection-group/" + cur["id"], sub, tok=tok)
        print("   exists without a preview subgroup; added it -> http %s %s" % (st, safe(d)))
else:
    ng = {k: v for k, v in g.items() if k not in ("id", "secretRefs", sk)}
    ng.setdefault("readOnly", False)
    ng["name"] = NEW; ng["connectionId"] = NEW; ng[sk] = [sub]
    st, d = call("POST", E, ng, tok=tok)
    print("   create -> http %s %s" % (st, safe(d)))
    if st not in (200, 201): sys.exit("   the engine refused the new connection. Nothing else was changed.")
fin = [x for x in groups() if x.get("name") == NEW]
if not fin: sys.exit("   connection %r is not in the list after the call" % NEW)
cur = group(fin[0]["id"])
print("   now: %s" % json.dumps({"id": cur.get("id"), "connectionId": cur.get("connectionId"), "database": cur.get("database"),
      "subgroups": [{"name": s.get("name"), "queryRoles": s.get("queryRoles"), "warehouse": (s.get("extraProperties") or {}).get("warehouse"),
                     "accessType": (s.get("extraProperties") or {}).get("accessType")} for s in cur[subkey(cur)]]}))
print("\nDone. Canary UI -> Settings -> Expected answers (golden SQL) -> Engine data connection = %s, then Test configuration." % cur.get("connectionId"))
PY
unset CSEC CANARY_PAT
REMOTE
} | ssh -o BatchMode=yes -o LogLevel=ERROR -i "$KEY" "$HOST" "IFS= read -r CANARY_PAT; export CANARY_PAT PUBLIC_URL='$URL' SRC='$SRC' NEW='$NEW' FROM_SUBGROUP='$FROM_SUBGROUP'; bash -s"
