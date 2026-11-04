#!/usr/bin/env bash
# Set up an agent from this repo: skills, settings, MCP servers and the global CLAUDE.md.
#
#   ./install.sh claude                  skills and tools linked to this checkout (live), settings merged, MCP servers added
#   ./install.sh claude --release [TAG]  same, from a release worktree of TAG (default: newest vA.B.C tag)
#   ./install.sh claude --check          report what is missing or differs, change nothing
#   ./install.sh claude --uninstall      remove only what this script added
#   --skills-only | --settings-only      only the skill links | only settings and MCP servers
#   --tools-only                         only the tool links in ~/.local/bin
#   --claude-md-only                     only ~/.claude/CLAUDE.md (created from the template if missing)
#   --force                              take the links (or our MCP registration) over from another checkout
#
# Skills: a link is ours when it is a symlink named workai-* whose target
# ends in /skills/<same name>. Anything else in the target folder is never
# touched. Links that point into another checkout that still exists (a
# second clone, a card worktree, the main checkout when installing a
# release) are only replaced with --force; links into a checkout that is
# gone are repaired. Release worktrees live in $WORKAI_RELEASES_DIR
# (default ~/.local/share/workai-playbooks/releases/<tag>), detached at the
# tag and locked against `git worktree prune`.
#
# Settings: claude/settings.fragment.json (plus settings.fragment.<os>.json,
# e.g. darwin) is merged into ~/.claude/settings.json with jq: objects key by
# key, arrays unioned, keys never removed, a value that differs is reported
# and left alone. Written only when the result differs, after a timestamped
# backup settings.json.workai-<time>.bak. What was added is recorded in
# ~/.claude/workai-installed.json, which --uninstall reads.
#
# Tools: tools/workai-*/<same name> (an executable, e.g.
# tools/workai-secret/workai-secret) is linked into $WORKAI_BIN_DIR (default
# ~/.local/bin), with the same ownership rules as skill links.
#
# MCP servers: claude/mcp.json, added with `claude mcp add --scope user`
# unless `claude mcp get <name>` already finds one (never by editing
# ~/.claude.json). One this script added (in the manifest) is re-registered
# with --force, or with --release when its command is in an older release
# worktree; any other differing registration is left as it is. No secret is ever passed to `claude mcp add`: a server
# that needs one is a wrapper script that reads it at launch.
#
# CLAUDE.md: never touched when it exists; created from claude/CLAUDE.md.template
# when missing (see the CLAUDE.md section below).
#
# Environment: CLAUDE_SKILLS_DIR, CLAUDE_CONFIG_HOME (default ~/.claude),
# CLAUDE_BIN (default claude), WORKAI_OS (default uname -s),
# WORKAI_BIN_DIR (default ~/.local/bin),
# WORKAI_INSTALL_PARTS (default skills,settings,mcp,tools,claudemd).
set -u

repo="$(cd "$(dirname "$0")" && pwd)"
releases="${WORKAI_RELEASES_DIR:-$HOME/.local/share/workai-playbooks/releases}"

usage() { sed -n '4,11p' "$0" | sed 's/^# *//'; exit 2; }

agent="${1:-}"; [ $# -gt 0 ] && shift
case "$agent" in
  claude) dest="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
          cdir="${CLAUDE_CONFIG_HOME:-$HOME/.claude}"
          claude_bin="${CLAUDE_BIN:-claude}" ;;
  *) usage ;;
esac
mode=install; release=0; tag=""; force=0
parts=",${WORKAI_INSTALL_PARTS:-skills,settings,mcp,tools,claudemd},"
bin_dir="${WORKAI_BIN_DIR:-$HOME/.local/bin}"
while [ $# -gt 0 ]; do
  case "$1" in
    --check|--uninstall) mode="$1" ;;
    --release) release=1
      case "${2:-}" in v[0-9]*) tag="$2"; shift ;; esac ;;
    --force) force=1 ;;
    --skills-only) parts=",skills," ;;
    --settings-only) parts=",settings,mcp," ;;
    --tools-only) parts=",tools," ;;
    --claude-md-only) parts=",claudemd," ;;
    *) usage ;;
  esac
  shift
done

root="$repo"
if [ "$release" = 1 ]; then
  if [ -z "$tag" ]; then
    tag="$(git -C "$repo" tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | head -1)"
    [ -n "$tag" ] || { echo "no vA.B.C tag in $repo"; exit 1; }
  fi
  git -C "$repo" rev-parse -q --verify "refs/tags/$tag" >/dev/null || { echo "no tag $tag in $repo"; exit 1; }
  root="$releases/$tag"
  if [ -d "$root" ]; then
    [ "$(git -C "$root" rev-parse HEAD 2>/dev/null)" = "$(git -C "$repo" rev-parse "$tag^{commit}")" ] \
      || { echo "$root exists but is not $tag; remove it first"; exit 1; }
  elif [ "$mode" = install ]; then
    mkdir -p "$releases"
    git -C "$repo" worktree add -q --detach "$root" "$tag" || { echo "could not create $root"; exit 1; }
    git -C "$repo" worktree lock --reason "workai-playbooks release $tag (install.sh)" "$root" 2>/dev/null
    echo "release  $tag at $root"
  fi
  [ -f "$root/VERSION" ] || [ "$mode" != install ] || { echo "$root has no VERSION"; exit 1; }
elif case "$parts" in *,skills,*|*,mcp,*|*,tools,*|*,claudemd,*) true ;; *) false ;; esac \
     && [ "$(git -C "$repo" rev-parse --git-dir 2>/dev/null)" != "$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null)" ]; then
  echo "warning: $repo is a linked worktree; links and MCP wrappers will point at it and follow its branch"
fi
src="$root/skills"

is_ours() { # path
  local name target
  name="$(basename "$1")"
  [ -L "$1" ] || return 1
  case "$name" in workai-*) ;; *) return 1 ;; esac
  target="$(readlink "$1")"
  case "$target" in */skills/"$name") return 0 ;; esac
  return 1
}

# The checkout an existing link of ours points into ("" if it is gone).
link_root() { # link
  local r; r="$(dirname "$(dirname "$(readlink "$1")")")"
  [ -d "$r/skills" ] && echo "$r"
}

# May this script replace our link at $1? Yes when its checkout is gone or is
# a release worktree being replaced by another release, or with --force.
may_replace() { # link
  local old; old="$(link_root "$1")"
  [ -z "$old" ] && return 0
  [ "$force" = 1 ] && return 0
  [ "$release" = 1 ] && case "$old" in "$releases"/*) return 0 ;; esac
  return 1
}

problems=0
note() { echo "$1"; }
problem() { echo "$1"; problems=$((problems + 1)); }
want() { case "$parts" in *,"$1",*) return 0 ;; esac; return 1; }

# ---------------------------------------------------------------- skills
skills_uninstall() {
  [ -d "$dest" ] || { note "nothing to remove: $dest does not exist"; return; }
  for link in "$dest"/workai-*; do
    [ -e "$link" ] || [ -L "$link" ] || continue
    if is_ours "$link"; then rm "$link" && note "removed  $(basename "$link")"
    else note "kept     $(basename "$link") (not installed by this script)"; fi
  done
}

skills_install() { # also --check
  [ "$mode" = "install" ] && mkdir -p "$dest"
  [ -d "$src" ] || { problem "missing  $src (run without --check to create the release worktree)"; return; }

  # Skills in this checkout.
  for skill in "$src"/*/; do
    [ -f "$skill/SKILL.md" ] || continue
    name="$(basename "$skill")"; want="$src/$name"; link="$dest/$name"
    if [ -L "$link" ] && [ "$(readlink "$link")" = "$want" ]; then
      note "ok       $name"
    elif [ ! -e "$link" ] && [ ! -L "$link" ]; then
      if [ "$mode" = "--check" ]; then problem "missing  $name"
      else ln -s "$want" "$link" && note "linked   $name"; fi
    elif is_ours "$link"; then
      if [ "$mode" = "--check" ]; then problem "wrong    $name -> $(readlink "$link")"
      elif may_replace "$link"; then old="$(readlink "$link")"; rm "$link" && ln -s "$want" "$link" && note "relinked $name (was $old)"
      else problem "refused  $name: linked to another checkout, $(link_root "$link") (use --force to take it over)"; fi
    else
      problem "refused  $name: $link exists and was not installed by this script"
    fi
  done

  # Our links whose skill no longer exists in this checkout.
  for link in "$dest"/workai-*; do
    [ -L "$link" ] || continue
    name="$(basename "$link")"
    [ -f "$src/$name/SKILL.md" ] && continue
    is_ours "$link" || continue
    if [ "$mode" = "--check" ]; then problem "orphan   $name -> $(readlink "$link")"
    elif [ -n "$(link_root "$link")" ] && [ "$(link_root "$link")" != "$root" ] && ! may_replace "$link"; then
      problem "refused  $name: belongs to another checkout, $(link_root "$link") (use --force to remove it)"
    else rm "$link" && note "removed  $name (no longer in $src)"; fi
  done
}

# ----------------------------------------------------------------- tools
# A tool link is ours when it is a symlink named workai-* whose target ends
# in /tools/<same name>/<same name>.
tool_is_ours() { # path
  local name; name="$(basename "$1")"
  [ -L "$1" ] || return 1
  case "$name" in workai-*) ;; *) return 1 ;; esac
  case "$(readlink "$1")" in */tools/"$name"/"$name") return 0 ;; esac
  return 1
}

tool_may_replace() { # link
  local old; old="$(dirname "$(dirname "$(dirname "$(readlink "$1")")")")"
  [ -d "$old/tools" ] || return 0
  [ "$force" = 1 ] && return 0
  [ "$release" = 1 ] && case "$old" in "$releases"/*) return 0 ;; esac
  return 1
}

tools_install() { # also --check
  local t name want link
  [ "$mode" = "install" ] && mkdir -p "$bin_dir"
  for t in "$root"/tools/workai-*/; do
    name="$(basename "$t")"; want="$root/tools/$name/$name"
    [ -f "$want" ] && [ -x "$want" ] || continue
    link="$bin_dir/$name"
    if [ -L "$link" ] && [ "$(readlink "$link")" = "$want" ]; then
      note "ok       bin/$name"
    elif [ ! -e "$link" ] && [ ! -L "$link" ]; then
      if [ "$mode" = "--check" ]; then problem "missing  bin/$name"
      else ln -s "$want" "$link" && note "linked   bin/$name"; fi
    elif tool_is_ours "$link"; then
      if [ "$mode" = "--check" ]; then problem "wrong    bin/$name -> $(readlink "$link")"
      elif tool_may_replace "$link"; then rm "$link" && ln -s "$want" "$link" && note "relinked bin/$name"
      else problem "refused  bin/$name: linked to another checkout (use --force to take it over)"; fi
    else
      problem "refused  bin/$name: $link exists and was not installed by this script"
    fi
  done
  if [ "$mode" = install ]; then
    case ":$PATH:" in *:"$bin_dir":*) ;; *) note "note     $bin_dir is not on PATH" ;; esac
  fi
}

tools_uninstall() {
  local link
  for link in "$bin_dir"/workai-*; do
    [ -L "$link" ] || continue
    tool_is_ours "$link" && rm "$link" && note "removed  bin/$(basename "$link")"
  done
}

# ------------------------------------------------------ manifest (shared)
settings="$cdir/settings.json"
manifest="$cdir/workai-installed.json"
os="$(echo "${WORKAI_OS:-$(uname -s)}" | tr 'A-Z' 'a-z')"
stamp="$(date +%Y%m%d-%H%M%S)"

need_jq() {
  [ "$(jq -n 1 2>/dev/null)" = 1 ] && return 0
  problem "missing  jq (needed for settings and MCP bookkeeping)"; return 1
}

manifest_read() { # -> stdout, {} when absent
  if [ -f "$manifest" ]; then jq -c . "$manifest" 2>/dev/null || { echo "unreadable $manifest" >&2; return 1; }
  else echo '{}'; fi
}

manifest_write() { # json
  local new="$1" tmpf
  if [ "$(echo "$new" | jq -c 'del(.version) | with_entries(select(.value != [] and .value != {} and .value != null))')" = "{}" ]; then
    [ -f "$manifest" ] && rm "$manifest" && note "removed  $manifest (nothing left installed)"
    return 0
  fi
  [ -f "$manifest" ] && [ "$(jq -cS . "$manifest")" = "$(echo "$new" | jq -cS .)" ] && return 0
  mkdir -p "$cdir"; tmpf="$(mktemp "$manifest.XXXXXX")"
  echo "$new" | jq . >"$tmpf" && mv "$tmpf" "$manifest"
}

fmt_path() { jq -r 'map(tostring) | join(".")'; }

# ------------------------------------------------------------- settings
fragment() { # merged fragment for this OS -> stdout, "" when none
  local base="$root/claude/settings.fragment.json" extra="$root/claude/settings.fragment.$os.json"
  [ -f "$base" ] || return 0
  if [ -f "$extra" ]; then jq -s '.[0] * .[1]' "$base" "$extra"; else jq . "$base"; fi
}

current_settings() {
  if [ -f "$settings" ]; then jq -c . "$settings" 2>/dev/null || return 1
  else echo '{}'; fi
}

write_settings() { # json  (backup first; temp file + mv, keeping the mode)
  local tmpf
  [ -L "$settings" ] && { problem "refused  $settings is a symlink; not writing through it"; return 1; }
  mkdir -p "$cdir"
  if [ -f "$settings" ]; then
    cp -p "$settings" "$settings.workai-$stamp.bak" && note "backup   $settings.workai-$stamp.bak"
    tmpf="$settings.workai-tmp.$$"; cp -p "$settings" "$tmpf"
  else tmpf="$(mktemp "$settings.XXXXXX")"; fi
  echo "$1" | jq --indent 2 . >"$tmpf" && mv "$tmpf" "$settings"
}

settings_install() { # also --check
  local frag cur res man
  frag="$(fragment)"
  [ -n "$frag" ] || { note "skip     settings: no claude/settings.fragment.json in $root"; return; }
  cur="$(current_settings)" || { problem "refused  $settings is not valid JSON; fix it by hand"; return; }
  res="$(echo "$cur" | jq -c --argjson frag "$frag" -f "$repo/claude/merge-settings.jq")" \
    || { problem "failed   merging settings"; return; }
  echo "$res" | jq -r '.conflicts[] | "differs  settings \(.path|map(tostring)|join(".")): have \(.have|tojson), repo has \(.want|tojson) (left as it is)"'
  if [ "$(echo "$res" | jq -c '.doc')" = "$(echo "$cur" | jq -c .)" ]; then
    note "ok       settings ($settings)"; return
  fi
  if [ "$mode" = "--check" ]; then
    echo "$res" | jq -r '(.keys[] | "missing  settings \(.path|map(tostring)|join(".")) = \(.value|tojson)"),
                         (.items[] | "missing  settings \(.path|map(tostring)|join(".")) item \(.value|tojson)")' \
      | while IFS= read -r l; do echo "$l"; done
    problems=$((problems + $(echo "$res" | jq '(.keys|length) + (.items|length)')))
    return
  fi
  write_settings "$(echo "$res" | jq -c .doc)" || return
  echo "$res" | jq -r '(.keys[] | "set      settings \(.path|map(tostring)|join(".")) = \(.value|tojson)"),
                       (.items[] | "added    settings \(.path|map(tostring)|join(".")) item \(.value|tojson)")'
  man="$(manifest_read)" || { problem "refused  $manifest is not valid JSON"; return; }
  manifest_write "$(echo "$man" | jq -c --argjson r "$res" '
      .version = 1
    | .settings.keys = ((.settings.keys // []) + $r.keys | unique)
    | .settings.items = ((.settings.items // []) + $r.items | unique)
    | .settings.created = ((.settings.created // []) + $r.created | unique)')"
}

settings_uninstall() {
  local man sect cur res
  man="$(manifest_read)" || { problem "refused  $manifest is not valid JSON"; return; }
  sect="$(echo "$man" | jq -c '.settings // {}')"
  [ "$sect" = "{}" ] && { note "nothing  settings (none recorded in $manifest)"; return; }
  cur="$(current_settings)" || { problem "refused  $settings is not valid JSON; fix it by hand"; return; }
  res="$(echo "$cur" | jq -c --argjson man "$sect" -f "$repo/claude/unmerge-settings.jq")" || { problem "failed   unmerging settings"; return; }
  echo "$res" | jq -r '.kept[] | "kept     settings \(.path|map(tostring)|join(".")): now \(.now|tojson), changed since install"'
  if [ "$(echo "$res" | jq -c .doc)" != "$(echo "$cur" | jq -c .)" ]; then
    write_settings "$(echo "$res" | jq -c .doc)" || return
    note "removed  settings this script added"
  fi
  manifest_write "$(echo "$man" | jq -c 'del(.settings)')"
}

# ------------------------------------------------------------------ MCP
mcp_names() { [ -f "$root/claude/mcp.json" ] && jq -r 'keys[]' "$root/claude/mcp.json"; }
have_claude() { command -v "$claude_bin" >/dev/null 2>&1 || { problem "missing  claude CLI ($claude_bin): MCP servers not checked"; return 1; }; }

# May this script re-register MCP server $1, now registered as `claude mcp
# get` output $2? Only one it added (in the manifest), and only with --force
# or when its command is in a release worktree being replaced by another
# release (as may_replace does for links).
mcp_may_replace() { # name get-output
  local man old
  [ "$mode" = install ] || return 1
  man="$(manifest_read)" || return 1
  echo "$man" | jq -e --arg n "$1" 'any((.mcp // [])[]; . == $n)' >/dev/null || return 1
  [ "$force" = 1 ] && return 0
  old="$(printf '%s\n' "$2" | sed -n 's/^ *Command: *//p' | head -1)"
  [ "$release" = 1 ] && case "$old" in "$releases"/*) return 0 ;; esac
  return 1
}

mcp_install() { # also --check
  local name cmd out man
  [ -f "$root/claude/mcp.json" ] || { note "skip     mcp: no claude/mcp.json in $root"; return; }
  have_claude || return
  for name in $(mcp_names); do
    cmd="$root/$(jq -r --arg n "$name" '.[$n].command' "$root/claude/mcp.json")"
    if out="$("$claude_bin" mcp get "$name" 2>&1)"; then
      if printf '%s\n' "$out" | grep -qF "$cmd"; then note "ok       mcp $name"; continue; fi
      if mcp_may_replace "$name" "$out"; then
        "$claude_bin" mcp remove --scope user "$name" >/dev/null 2>&1 \
          && "$claude_bin" mcp add --scope user "$name" -- "$cmd" >/dev/null 2>&1 \
          && note "replaced mcp $name -> $cmd" || problem "failed   mcp $name: could not re-register"
      else
        note "differs  mcp $name: already registered with another command (left as it is; --force, or --release over an older release, replaces one this script added)"
      fi
      continue
    fi
    if [ "$mode" = "--check" ]; then problem "missing  mcp $name"; continue; fi
    [ -x "$cmd" ] || { problem "missing  $cmd"; continue; }
    if "$claude_bin" mcp add --scope user "$name" -- "$cmd" >/dev/null 2>&1; then
      note "added    mcp $name -> $cmd"
      man="$(manifest_read)" || man='{}'
      manifest_write "$(echo "$man" | jq -c --arg n "$name" '.version = 1 | .mcp = ((.mcp // []) + [$n] | unique)')"
    else problem "failed   claude mcp add $name"; fi
  done
}

mcp_uninstall() {
  local man name out
  man="$(manifest_read)" || { problem "refused  $manifest is not valid JSON"; return; }
  [ "$(echo "$man" | jq '(.mcp // []) | length')" = 0 ] && { note "nothing  mcp (none recorded in $manifest)"; return; }
  have_claude || return
  for name in $(echo "$man" | jq -r '.mcp[]'); do
    if ! out="$("$claude_bin" mcp get "$name" 2>&1)"; then note "gone     mcp $name"
    elif printf '%s\n' "$out" | grep -qF "/claude/mcp/"; then
      "$claude_bin" mcp remove --scope user "$name" >/dev/null 2>&1 && note "removed  mcp $name" || { problem "failed   claude mcp remove $name"; continue; }
    else note "kept     mcp $name (registered with another command since)"; fi
    man="$(echo "$man" | jq -c --arg n "$name" '.mcp -= [$n]')"
  done
  manifest_write "$man"
}

# ------------------------------------------------------------ CLAUDE.md
# ~/.claude/CLAUDE.md belongs to the user. Install never touches one that is
# there (a file, or any symlink other than the old link below): `kept`. Only
# when it is missing is claude/CLAUDE.md.template copied there as a plain
# file, recorded in the manifest with its sha256 (.claude_md = {created,
# sha256}). --uninstall removes it only while it is still byte-identical to
# what was written.
# Migration (card 01-155): the link older versions made (card 01-152) into
# a workai-playbooks checkout or release (.../claude/CLAUDE.md) is replaced
# by a plain file with the link target's current content (from git when the
# target is gone): nothing changes for the session, and the file is the
# user's from then on.
cmd_file="$cdir/CLAUDE.md"

sha256_of() { # file -> hash
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# Is $cmd_file the link card 152 made (into a checkout or release of this
# repo)? Known by its target, or, when that checkout is gone, by the
# manifest entry card 152 wrote (.claude_md.installed).
cmd_is_old_link() {
  local t d
  [ -L "$cmd_file" ] || return 1
  t="$(readlink "$cmd_file")"
  case "$t" in */claude/CLAUDE.md) ;; *) return 1 ;; esac
  d="$(dirname "$(dirname "$t")")"
  [ "$d" = "$repo" ] && return 0
  case "$d" in "$releases"/*) return 0 ;; esac
  [ -f "$d/install.sh" ] && [ -f "$d/skills/workai-structure/SKILL.md" ] && return 0
  [ ! -e "$t" ] && [ "$(manifest_read 2>/dev/null | jq -r '.claude_md.installed // false' 2>/dev/null)" = true ]
}

# claude/CLAUDE.md of a git checkout: at HEAD, or just before the commit that
# removed it. Writes it to $2, prints where it came from.
rules_in_git() { # checkout out
  local h
  git -C "$1" rev-parse --git-dir >/dev/null 2>&1 || return 1
  if git -C "$1" cat-file -e HEAD:claude/CLAUDE.md 2>/dev/null; then h=HEAD
  else h="$(git -C "$1" log -1 --format=%H -- claude/CLAUDE.md 2>/dev/null)"; [ -n "$h" ] || return 1; h="$h^"; fi
  git -C "$1" show "$h:claude/CLAUDE.md" >"$2" 2>/dev/null || return 1
  echo "its last content in git ($1 at $(git -C "$1" rev-parse --short "$h"))"
}

# The link's target is gone: write the content it last had to $2 and print
# where it came from. A release: the tag's file. A checkout: its own git
# history if the checkout is still a repository, else this repo's.
old_rules_from_git() { # target out
  local d tag
  d="$(dirname "$(dirname "$1")")"
  case "$d" in "$releases"/*)
    tag="$(basename "$d")"
    git -C "$repo" show "refs/tags/$tag:claude/CLAUDE.md" >"$2" 2>/dev/null && { echo "the content of $tag"; return 0; }
    return 1 ;;
  esac
  [ "$d" != "$repo" ] && [ -d "$d" ] && rules_in_git "$d" "$2" && return 0
  rules_in_git "$repo" "$2"
}

# Was $cmd_file written by this script and not changed since?
cmd_is_ours() {
  local h
  [ -f "$cmd_file" ] && [ ! -L "$cmd_file" ] || return 1
  h="$(manifest_read 2>/dev/null | jq -r '.claude_md.sha256 // ""')"
  [ -n "$h" ] && [ "$(sha256_of "$cmd_file")" = "$h" ]
}

claudemd_install() { # also --check
  local tpl="$root/claude/CLAUDE.md.template" target tmpf man from bak
  man="$(manifest_read)" || { problem "refused  CLAUDE.md: $manifest is not valid JSON"; return; }
  if cmd_is_old_link; then
    target="$(readlink "$cmd_file")"
    tmpf="$cmd_file.workai-tmp.$$"
    if [ -f "$target" ]; then
      from="its content"
      [ "$mode" = "--check" ] || cp "$target" "$tmpf" || { rm -f "$tmpf"; problem "failed   copying $target to $cmd_file"; return; }
    elif from="$(old_rules_from_git "$target" "$tmpf")"; then
      [ "$mode" = "--check" ] && rm -f "$tmpf"
    else
      rm -f "$tmpf"
      problem "refused  CLAUDE.md: links to $target, which is gone and not in git history; remove the link to get the template"; return
    fi
    [ "$mode" = "--check" ] && { problem "linked   CLAUDE.md -> $target (install turns it into a plain file with $from)"; return; }
    mv "$tmpf" "$cmd_file" || { rm -f "$tmpf"; problem "failed   writing $cmd_file"; return; }
    note "migrated CLAUDE.md: the link to $target is now a plain file with $from (yours from now on)"
    bak="$(echo "$man" | jq -r '.claude_md.backup // ""')"
    [ -n "$bak" ] && note "note     the old backup $bak is left as it is"
    manifest_write "$(echo "$man" | jq -c 'del(.claude_md)')"
    return
  fi
  if [ -e "$cmd_file" ] || [ -L "$cmd_file" ]; then
    if cmd_is_ours; then note "ours     CLAUDE.md (created from the template, unchanged)"
    else note "kept     CLAUDE.md ($cmd_file is yours; never changed)"; fi
    return
  fi
  [ -f "$tpl" ] || { note "skip     CLAUDE.md: no claude/CLAUDE.md.template in $root"; return; }
  [ "$mode" = "--check" ] && { problem "missing  CLAUDE.md ($cmd_file; install copies the template)"; return; }
  mkdir -p "$cdir"
  tmpf="$cmd_file.workai-tmp.$$"
  cp "$tpl" "$tmpf" && mv "$tmpf" "$cmd_file" || { rm -f "$tmpf"; problem "failed   writing $cmd_file"; return; }
  note "created  CLAUDE.md from $tpl"
  manifest_write "$(echo "$man" | jq -c --arg h "$(sha256_of "$cmd_file")" '.version = 1 | .claude_md = {created: true, sha256: $h}')"
}

claudemd_uninstall() {
  local man bak
  man="$(manifest_read)" || { problem "refused  $manifest is not valid JSON"; return; }
  if cmd_is_old_link; then # card 152's link, never migrated: undo it as 152 did
    bak="$(echo "$man" | jq -r '.claude_md.backup // ""')"
    rm "$cmd_file" && note "removed  CLAUDE.md link (made by an older version)"
    if [ -n "$bak" ]; then
      if [ -e "$bak" ] || [ -L "$bak" ]; then mv "$bak" "$cmd_file" && note "restored CLAUDE.md from $bak"
      else problem "missing  backup $bak: CLAUDE.md not restored"; fi
    fi
  elif [ "$(echo "$man" | jq -c '.claude_md // null')" = null ]; then
    { [ -e "$cmd_file" ] || [ -L "$cmd_file" ]; } && note "kept     CLAUDE.md (not created by this script)"
    return
  elif cmd_is_ours; then rm "$cmd_file" && note "removed  CLAUDE.md (created from the template, unchanged)"
  elif [ -e "$cmd_file" ] || [ -L "$cmd_file" ]; then note "kept     CLAUDE.md (changed since it was created, or not created by this script)"
  fi
  manifest_write "$(echo "$man" | jq -c 'del(.claude_md)')"
}

# ----------------------------------------------------------------- main
if [ "$mode" = "--uninstall" ]; then
  want skills && skills_uninstall
  want tools && tools_uninstall
  if want settings || want mcp; then
    if need_jq; then
      want mcp && mcp_uninstall
      want settings && settings_uninstall
    fi
  fi
  want claudemd && need_jq && claudemd_uninstall
else
  want skills && skills_install
  want tools && tools_install
  if want settings || want mcp; then
    if need_jq; then
      want settings && settings_install
      want mcp && mcp_install
    fi
  fi
  want claudemd && need_jq && claudemd_install
fi

if [ "$problems" -gt 0 ]; then
  echo "$problems problem(s)"
  exit 1
fi
exit 0
