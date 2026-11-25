#!/usr/bin/env bash
# demo1: the MCP server's Keycloak service account (client "atscale-mcp") cannot get a token: Keycloak answers
# "Invalid client or Invalid client credentials" for the secret the MCP server holds (k8s secret atscale-kc-clients).
# Canary's background runs and golden SQL use that service account (docs/canary/golden-sql-engine.md, step 3).
#
#   bash ~/GitHub/atscale-deploy-action/scripts/demo1-kc-mcp-client.sh         check: read-only report, changes nothing
#   bash ~/GitHub/atscale-deploy-action/scripts/demo1-kc-mcp-client.sh fix     make Keycloak match, then report again
#
# check reports, for clients atscale-mcp and atscale-mcp-engine: whether Keycloak's stored secret equals the one in the
#   k8s secret, whether service accounts are on, and (atscale-mcp) which of the two engine realm roles its service
#   account has: query_dataset_api_view and datawarehouses_admin (what swtdev's service account has).
# fix   sets Keycloak's stored secret to the k8s value where they differ (the pods already hold the k8s value, so no
#   restart), turns service accounts on for atscale-mcp, and gives its service account the two realm roles.
# The Keycloak admin login and the client secrets stay on the VM: never printed, never on a command line.
set -euo pipefail
MODE="${1:-check}"; case "$MODE" in check|fix) ;; *) sed -n '2,13p' "$0"; exit 1 ;; esac
KEY="${KEY:-$HOME/.ssh/id_rsa}"; HOST="${HOST:-atscale@172.203.218.112}"
ssh -o BatchMode=yes -o LogLevel=ERROR -i "$KEY" "$HOST" "MODE='$MODE' bash -s" <<'REMOTE'
set -euo pipefail
K="sudo microk8s kubectl -n atscale"
IP=$($K get svc atscale-keycloak -o 'jsonpath={.spec.clusterIP}' </dev/null)
PORT=$($K get svc atscale-keycloak -o 'jsonpath={.spec.ports[0].port}' </dev/null)
export KC_BASE="http://$IP:$PORT/auth"
export KC_U=$($K get secret atscale-kc-users -o 'jsonpath={.data.keycloakAdmin}' </dev/null | base64 -d)
export KC_P=$($K get secret atscale-kc-users -o 'jsonpath={.data.keycloakAdminPassword}' </dev/null | base64 -d)
export S_MCP=$($K get secret atscale-kc-clients -o 'jsonpath={.data.mcp}' </dev/null | base64 -d)
export S_ENG=$($K get secret atscale-kc-clients -o 'jsonpath={.data.mcpEngine}' </dev/null | base64 -d)
python3 - <<'PY'
import os, json, urllib.request, urllib.parse, urllib.error
B = os.environ["KC_BASE"]; R = B + "/admin/realms/atscale"; MODE = os.environ["MODE"]
def call(method, url, body=None, tok=None, form=False):
    data = None; h = {}
    if body is not None:
        if form: data = urllib.parse.urlencode(body).encode(); h["Content-Type"] = "application/x-www-form-urlencoded"
        else: data = json.dumps(body).encode(); h["Content-Type"] = "application/json"
    if tok: h["Authorization"] = "Bearer " + tok
    try:
        with urllib.request.urlopen(urllib.request.Request(url, data=data, headers=h, method=method), timeout=30) as r:
            t = r.read().decode(); return r.status, (json.loads(t) if t else None)
    except urllib.error.HTTPError as e:
        t = e.read().decode()
        try: return e.code, json.loads(t)
        except Exception: return e.code, {"raw": t[:200]}
st, d = call("POST", B + "/realms/master/protocol/openid-connect/token",
             {"client_id": "admin-cli", "grant_type": "password", "username": os.environ["KC_U"], "password": os.environ["KC_P"]}, form=True)
tok = (d or {}).get("access_token")
if not tok: raise SystemExit("Keycloak admin login failed (http %s)" % st)
WANT = ["query_dataset_api_view", "datawarehouses_admin"]
def report(cid, k8s_secret, roles):
    st, lst = call("GET", R + "/clients?clientId=" + cid, tok=tok)
    if not lst: print("%s: client NOT FOUND in Keycloak" % cid); return None
    c = lst[0]
    st, sec = call("GET", R + "/clients/%s/client-secret" % c["id"], tok=tok)
    same = (sec or {}).get("value") == k8s_secret
    print("%s: k8s secret present=%s | Keycloak secret equals k8s secret=%s | serviceAccountsEnabled=%s | publicClient=%s"
          % (cid, bool(k8s_secret), same, c.get("serviceAccountsEnabled"), c.get("publicClient")))
    have = None
    if roles and c.get("serviceAccountsEnabled"):
        st, u = call("GET", R + "/clients/%s/service-account-user" % c["id"], tok=tok)
        if st == 200:
            st, rm = call("GET", R + "/users/%s/role-mappings/realm/composite" % u["id"], tok=tok)
            have = sorted(r["name"] for r in (rm or []))
            print("   service account realm roles (effective): %s" % have)
            print("   has the two engine roles: %s" % {w: (w in have or "admin" in have) for w in WANT})
    return c, same, have
def fix(cid, k8s_secret, roles):
    r = report(cid, k8s_secret, roles)
    if r is None: return
    c, same, have = r
    changed = False
    if not k8s_secret: print("   no k8s secret value for %s: nothing to set" % cid); return
    if not same or (roles and not c.get("serviceAccountsEnabled")):
        c["secret"] = k8s_secret
        if roles: c["serviceAccountsEnabled"] = True
        st, _ = call("PUT", R + "/clients/%s" % c["id"], c, tok=tok)
        print("   PUT client -> http %s (204 = saved)" % st); changed = True
    if roles:
        st, u = call("GET", R + "/clients/%s/service-account-user" % c["id"], tok=tok)
        if st != 200: print("   service account user not found (http %s)" % st); return
        st, rm = call("GET", R + "/users/%s/role-mappings/realm/composite" % u["id"], tok=tok)
        have = [r["name"] for r in (rm or [])]
        add = []
        for w in WANT:
            if w in have or "admin" in have: continue
            st, role = call("GET", R + "/roles/" + w, tok=tok)
            if st == 200: add.append({"id": role["id"], "name": role["name"]})
            else: print("   realm role %s not found (http %s)" % (w, st))
        if add:
            st, _ = call("POST", R + "/users/%s/role-mappings/realm" % u["id"], add, tok=tok)
            print("   added realm roles %s -> http %s (204 = saved)" % ([a["name"] for a in add], st)); changed = True
    if not changed: print("   nothing to change")
pairs = [("atscale-mcp", os.environ.get("S_MCP", ""), True), ("atscale-mcp-engine", os.environ.get("S_ENG", ""), False)]
if MODE == "fix":
    print("=== fix"); [fix(*p) for p in pairs]
print("=== state now"); [report(*p) for p in pairs]
# Does the grant work now? (what the MCP server does for a Canary run)
st, d = call("POST", B + "/realms/atscale/protocol/openid-connect/token",
             {"grant_type": "client_credentials", "client_id": "atscale-mcp", "client_secret": os.environ.get("S_MCP", ""), "scope": "email openid profile"}, form=True)
print("client-credentials grant as atscale-mcp: %s" % ("OK" if (d or {}).get("access_token") else "FAILED: %s / %s" % ((d or {}).get("error"), (d or {}).get("error_description"))))
PY
unset KC_U KC_P S_MCP S_ENG
REMOTE
