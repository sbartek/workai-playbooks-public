# Undo what install.sh added to Claude Code settings (see merge-settings.jq).
#   input: the current settings object
#   $man:  the "settings" section of ~/.claude/workai-installed.json
# Removes the array items it added, the keys it added when they still hold
# the value it set, then the objects/arrays it created if they are now
# empty. Anything changed since is kept and reported in .kept.
# Output: {doc, kept: [{path, value, now}]}

def pathok(p): try (getpath(p) | true) catch false;

reduce ($man.items // [])[] as $it ({doc: ., kept: []};
  if ((.doc | pathok($it.path)) and (.doc | getpath($it.path) | type) == "array")
  then .doc |= setpath($it.path; getpath($it.path) | map(select(. != $it.value)))
  else . end)
| reduce ($man.keys // [])[] as $k (.;
    if (.doc | pathok($k.path)) | not then .
    elif (.doc | getpath($k.path)) == $k.value then .doc |= delpaths([$k.path])
    elif (.doc | getpath($k.path)) == null then .
    else .kept += [{path: $k.path, value: $k.value, now: (.doc | getpath($k.path))}] end)
| reduce (($man.created // []) | sort_by(length) | reverse)[] as $c (.;
    if ((.doc | pathok($c)) and ((.doc | getpath($c)) as $x | $x == {} or $x == []))
    then .doc |= delpaths([$c]) else . end)
