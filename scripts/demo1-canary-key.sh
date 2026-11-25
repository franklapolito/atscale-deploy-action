#!/usr/bin/env bash
# demo1 Canary: set the LLM API key that Canary runs use. Keys cannot be set on the Canary UI's Settings page: the MCP
# server reads them from its environment only (docs/guides/enabling-comodel-and-canary.md, step 5). On demo1 that is
# the Kubernetes Secret "atscale-mcp-canary", which the MCP server loads at start.
#
#   bash ~/GitHub/atscale-deploy-action/scripts/demo1-canary-key.sh           set or replace one key
#   bash ~/GitHub/atscale-deploy-action/scripts/demo1-canary-key.sh --list    show which key names are set (no values)
#
# It asks which provider the key is for and then for the key (not shown, not in shell history). The key goes to the
# VM on standard input, into the Secret through a pipe, and is never printed or put on a command line. The MCP server
# is restarted so it reads the key (about one minute; Design Center and the engine are not restarted).
# After it: open https://demo.poc.atscale-se-demo.com/ui/ -> Settings, set the agent LLM id, press Test configuration.
set -euo pipefail
KEY="${KEY:-$HOME/.ssh/id_rsa}"; HOST="${HOST:-atscale@172.203.218.112}"
SSH=(ssh -o BatchMode=yes -o LogLevel=ERROR -i "$KEY" "$HOST")
LIST='sudo microk8s kubectl -n atscale get secret atscale-mcp-canary -o go-template="{{range \$k,\$v := .data}}{{\$k}}{{\"\\n\"}}{{end}}"'
if [ "${1:-}" = "--list" ]; then echo "key names set in atscale-mcp-canary:"; "${SSH[@]}" "$LIST" | sed 's/^/  /'; exit 0; fi

echo "Which provider is this key for?"
echo "  1) OpenRouter (the default endpoint; model ids like openai/gpt-4.1-mini or anthropic/claude-sonnet-4.5)"
echo "  2) OpenAI direct (model ids that start with openai/)"
echo "  3) Anthropic direct (model ids that start with anthropic/)"
echo "  4) Engine token for runs (an AtScale API token from Design Center; runs then query the engine as that user)"
read -r -p "1, 2, 3 or 4: " C
case "$C" in
  1) NAME=ATSCALE_MCP_CANARY_API_KEY ;;
  2) NAME=ATSCALE_MCP_CANARY_OPENAI_API_KEY ;;
  3) NAME=ATSCALE_MCP_CANARY_ANTHROPIC_API_KEY ;;
  4) NAME=ATSCALE_MCP_CANARY_ENGINE_TOKEN ;;
  *) echo "not 1, 2, 3 or 4" >&2; exit 1 ;;
esac
read -rs -p "Key or token (not shown): " V; echo
[ -n "$V" ] || { echo "empty key" >&2; exit 1; }
{ printf '%s\n%s\n' "$NAME" "$V"; cat <<'REMOTE'
set -euo pipefail
K="sudo microk8s kubectl -n atscale"
python3 -c 'import json,os; print(json.dumps({"stringData":{os.environ["CANARY_KEY_NAME"]:os.environ["CANARY_KEY_VALUE"]}}))' \
  | $K patch secret atscale-mcp-canary --type merge --patch-file /dev/stdin >/dev/null && echo "secret updated: $CANARY_KEY_NAME"
unset CANARY_KEY_VALUE
$K rollout restart deploy/atscale-mcp-server </dev/null >/dev/null
$K rollout status deploy/atscale-mcp-server --timeout=240s </dev/null | tail -1
echo "key names now set:"; $K get secret atscale-mcp-canary -o go-template='{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}' </dev/null | sed 's/^/  /'
REMOTE
} | "${SSH[@]}" "IFS= read -r CANARY_KEY_NAME; IFS= read -r CANARY_KEY_VALUE; export CANARY_KEY_NAME CANARY_KEY_VALUE; bash -s"
echo
echo "Next: https://demo.poc.atscale-se-demo.com/ui/ -> Settings -> set the agent LLM id -> Test configuration."
