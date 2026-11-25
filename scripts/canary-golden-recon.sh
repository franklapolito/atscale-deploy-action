#!/usr/bin/env bash
# Read-only: list an environment's engine connections and their subgroups, to see how golden SQL is (or is not) set up
# (docs/canary/golden-sql-engine.md in AtScaleInc/mcp). It makes GET calls only and changes nothing.
#   bash scripts/canary-golden-recon.sh swtdev
#   bash scripts/canary-golden-recon.sh demo1
# The token is taken on the VM (the MCP server's own service account, from the k8s secret) and stays there: it is never
# printed and never put on a command line. Credentials of connections are not returned by the engine and are not shown.
set -euo pipefail
case "${1:-}" in
  swtdev) HOST=atscale@20.163.121.39; KEY="$(cd "$(dirname "$0")/.." && pwd)/runtime/swtdev_key"; URL=https://swtdev.atscalehosted.com ;;
  demo1)  HOST=atscale@172.203.218.112; KEY="$HOME/.ssh/id_rsa"; URL=https://demo.poc.atscale-se-demo.com ;;
  *) sed -n '2,6p' "$0"; exit 1 ;;
esac
ssh -o BatchMode=yes -o LogLevel=ERROR -i "$KEY" "$HOST" "PUBLIC_URL='$URL' bash -s" <<'REMOTE'
set -euo pipefail
K="sudo microk8s kubectl -n atscale"
val() { $K get secret "$1" -o "jsonpath={.data.$2}" </dev/null 2>/dev/null | base64 -d 2>/dev/null || true; }
CID="$($K get configmap atscale-mcp-server-extra-env -o 'jsonpath={.data.ATSCALE_MCP_KEYCLOAK_CLIENT_ID}' </dev/null 2>/dev/null || true)"
CSEC="$(val atscale-kc-clients mcp)"
[ -n "$CID" ] && [ -n "$CSEC" ] || { echo "MCP service account not found on this box"; exit 1; }
echo "service account client: $CID"
export CSEC
TOK=$(python3 -c 'import os,urllib.parse as u,sys; print(u.urlencode({"grant_type":"client_credentials","client_id":sys.argv[1],"client_secret":os.environ["CSEC"],"scope":"openid"}),end="")' "$CID" \
  | curl -sk -X POST "$PUBLIC_URL/auth/realms/atscale/protocol/openid-connect/token" --data-binary @- \
  | python3 -c 'import sys,json
d=json.load(sys.stdin)
if not d.get("access_token"): sys.stderr.write("Keycloak said: %s / %s\n" % (d.get("error"), d.get("error_description")))
print(d.get("access_token",""))')
unset CSEC
[ -n "$TOK" ] || { echo "no token from Keycloak for the service account"; exit 1; }
echo "token realm roles: $(printf '%s' "$TOK" | python3 -c 'import sys,json,base64; p=sys.stdin.read().split(".")[1]; c=json.loads(base64.urlsafe_b64decode(p+"=="*1)); print(sorted(c.get("realm_access",{}).get("roles",[])))' 2>/dev/null || echo unknown)"
code=$(curl -sk -o /tmp/cg.json -w '%{http_code}' -H "Authorization: Bearer $TOK" "$PUBLIC_URL/engine/connection-groups")
echo "GET /engine/connection-groups -> $code"
[ "$code" = 200 ] || { head -c 300 /tmp/cg.json; echo; rm -f /tmp/cg.json; exit 1; }
for id in $(python3 -c 'import json; [print(g["id"]) for g in json.load(open("/tmp/cg.json"))["response"]["results"]]'); do
  curl -sk -H "Authorization: Bearer $TOK" "$PUBLIC_URL/engine/connection-groups/connection-group/$id" | python3 -c '
import sys,json
g=json.load(sys.stdin)["response"]["results"]
if isinstance(g,list): g=g[0]
SAFE=("id","name","connectorType","hosts","port","database","username","queryRoles","extraJdbcFlags")
print("\nCONNECTION", json.dumps({k:g.get(k) for k in ("id","connectionId","name","platformType","database","aggregateSchema")}))
ep=g.get("extraProperties") or {}
print("  group extraProperties keys:", sorted(ep.keys()))
for s in g.get("subgroups") or g.get("connectionSubgroups") or []:
    d={k:s.get(k) for k in SAFE}
    e=s.get("extraProperties") or {}
    d["extraProperties"]={k:(v if k in ("accessType","keySource","role","warehouse","authenticator") else "[..]") for k,v in e.items()}
    d["secretRefs"]=sorted((s.get("secretRefs") or {}).keys()) if isinstance(s.get("secretRefs"),dict) else ("present" if s.get("secretRefs") else None)
    print("  SUBGROUP", json.dumps(d))
other=[k for k in g.keys() if k not in ("id","connectionId","name","platformType","database","aggregateSchema","extraProperties","subgroups","connectionSubgroups")]
print("  other group keys:", other)
'
done
rm -f /tmp/cg.json
REMOTE
