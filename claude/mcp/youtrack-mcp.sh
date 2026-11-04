#!/usr/bin/env bash
# Stdio MCP server for the local YouTrack Server (hub 01, notes/youtrack):
# a bridge to its built-in MCP endpoint through mcp-remote, with the API
# token read at launch, so it is never stored in ~/.claude.json, in a file
# of this repo, or on a command line.
#
# Registered by `install.sh claude` as:
#   claude mcp add --scope user youtrack -- <checkout>/claude/mcp/youtrack-mcp.sh
#
# Why not plain OAuth (`claude mcp add --transport http ... /mcp`): YouTrack
# does not support dynamic client registration (Claude Code answers
# "Incompatible auth server: does not support dynamic client registration"),
# so OAuth needs an OAuth client registered by hand in YouTrack first.
#
# Token: the secret `youtrack/api` of workai-secret (tools/workai-secret in
# this checkout: the macOS keychain, secret-tool or pass); else the file
# ${XDG_CONFIG_HOME:-~/.config}/workai/youtrack-token (mode 600).
# Settings (environment): YOUTRACK_MCP_URL (default http://127.0.0.1:8645/mcp).
set -eu

url="${YOUTRACK_MCP_URL:-http://127.0.0.1:8645/mcp}"
mcp_remote="mcp-remote@0.14.3"   # pinned: newest release older than two weeks on 2026-10-24

here="$(cd "$(dirname "$0")" && pwd)"
token="$("$here/../../tools/workai-secret/workai-secret" get youtrack/api 2>/dev/null)" || token=""
if [ -z "$token" ]; then
  f="${XDG_CONFIG_HOME:-$HOME/.config}/workai/youtrack-token"
  if [ -f "$f" ]; then
    case "$(ls -l "$f" | cut -c5-10)" in
      ------) token="$(tr -d '\r\n' <"$f")" ;;
      *) echo "youtrack-mcp: $f must not be readable by others (chmod 600)" >&2; exit 1 ;;
    esac
  fi
fi
[ -n "$token" ] || {
  echo "youtrack-mcp: no YouTrack token (workai-secret set youtrack/api, or ~/.config/workai/youtrack-token)" >&2
  exit 1
}
command -v npx >/dev/null 2>&1 || { echo "youtrack-mcp: npx not found (Node.js 18+ is needed)" >&2; exit 1; }

# mcp-remote expands ${VAR} in header values from its environment, so the
# token travels in the environment, not in the arguments.
export YOUTRACK_MCP_AUTH="Bearer $token"
unset token
exec npx -y "$mcp_remote" "$url" --transport http-only --allow-http \
  --header 'Authorization:${YOUTRACK_MCP_AUTH}'
