#!/usr/bin/env bash
# NOT NEEDED (2026-11-24): the develop Keycloak image creates the dedicated client atscale-canary-ui for the Canary UI.
# Leave ATSCALE_MCP_CANARY_UI_CLIENT_ID unset instead. Kept only as a record of what was tried on demo1.
# demo1 Canary UI sign-in (2026-11-23): let the Keycloak client "atscale-mcp-public" return to the Canary UI on demo1.
# The client exists (the chart creates it) but only accepts localhost return addresses, so the UI sign-in fails with
# "Invalid parameter: redirect_uri". This adds the same four addresses John's swtdev box accepts, the web origin, and
# pins PKCE to S256. It changes nothing on a rerun.
#
#   bash ~/GitHub/atscale-deploy-action/scripts/demo1-canary-ui.sh            apply
#   DRY_RUN=1 bash ~/GitHub/atscale-deploy-action/scripts/demo1-canary-ui.sh  show the client before and the change, apply nothing
#
# Frank runs this from his Mac (it reads the Keycloak admin login from the cluster). The admin login stays on the VM:
# it is never printed and never put on a command line. curl and python3 run on the VM against the Keycloak service IP.
set -euo pipefail
KEY="${KEY:-$HOME/.ssh/id_rsa}"; HOST="${HOST:-atscale@172.203.218.112}"
PUBLIC_URL="${PUBLIC_URL:-https://demo.poc.atscale-se-demo.com}"; DRY_RUN="${DRY_RUN:-0}"
ssh -o BatchMode=yes -o LogLevel=ERROR -i "$KEY" "$HOST" "PUBLIC_URL='$PUBLIC_URL' DRY_RUN='$DRY_RUN' bash -s" <<'REMOTE'
set -euo pipefail
K="sudo microk8s kubectl -n atscale"
IP=$($K get svc atscale-keycloak -o 'jsonpath={.spec.clusterIP}' </dev/null)
PORT=$($K get svc atscale-keycloak -o 'jsonpath={.spec.ports[0].port}' </dev/null)
BASE="http://$IP:$PORT/auth"; R="$BASE/admin/realms/atscale"
export KC_U=$($K get secret atscale-kc-users -o 'jsonpath={.data.keycloakAdmin}' </dev/null | base64 -d)
export KC_P=$($K get secret atscale-kc-users -o 'jsonpath={.data.keycloakAdminPassword}' </dev/null | base64 -d)
TOK=$(python3 -c 'import os,urllib.parse as u; print(u.urlencode({"client_id":"admin-cli","grant_type":"password","username":os.environ["KC_U"],"password":os.environ["KC_P"]}),end="")' \
  | curl -s -X POST "$BASE/realms/master/protocol/openid-connect/token" --data-binary @- \
  | python3 -c 'import sys,json; print(json.load(sys.stdin).get("access_token",""))')
unset KC_U KC_P
[ -n "$TOK" ] || { echo "admin login failed (no token)"; exit 1; }
CID=$(curl -s -H "Authorization: Bearer $TOK" "$R/clients?clientId=atscale-mcp-public" </dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d[0]["id"] if d else "")')
[ -n "$CID" ] || { echo "client atscale-mcp-public not found"; exit 1; }
curl -s -H "Authorization: Bearer $TOK" "$R/clients/$CID" </dev/null > /tmp/mcp-public.json
show() { python3 -c 'import sys,json; c=json.load(open(sys.argv[1])); print(json.dumps({"redirectUris":c.get("redirectUris"),"webOrigins":c.get("webOrigins"),"publicClient":c.get("publicClient"),"pkce":(c.get("attributes") or {}).get("pkce.code.challenge.method")},indent=1))' "$1"; }
echo "--- before"; show /tmp/mcp-public.json
python3 - "$PUBLIC_URL" <<'PY'
import sys,json
o=sys.argv[1].rstrip("/")
c=json.load(open("/tmp/mcp-public.json"))
add=[o+"/ui/callback", o+"/ui/", o+"/canary/callback", o+"/canary/"]
c["redirectUris"]=sorted(set((c.get("redirectUris") or [])+add))
c["webOrigins"]=sorted(set((c.get("webOrigins") or [])+[o]))
c.setdefault("attributes",{})["pkce.code.challenge.method"]="S256"
json.dump(c,open("/tmp/mcp-public.new.json","w"))
PY
echo "--- after (planned)"; show /tmp/mcp-public.new.json
if [ "$DRY_RUN" = 1 ]; then echo "dry run: nothing applied"; rm -f /tmp/mcp-public.json /tmp/mcp-public.new.json; exit 0; fi
code=$(curl -s -o /tmp/put.out -w '%{http_code}' -H "Authorization: Bearer $TOK" -X PUT "$R/clients/$CID" -H 'Content-Type: application/json' --data-binary @/tmp/mcp-public.new.json)
[ "$code" = 204 ] && echo "applied (http 204)" || { echo "FAILED http=$code $(head -c 200 /tmp/put.out)"; }
rm -f /tmp/mcp-public.json /tmp/mcp-public.new.json /tmp/put.out
REMOTE
