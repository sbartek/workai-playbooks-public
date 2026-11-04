# Merge a settings fragment into Claude Code settings without removing or
# overwriting anything (used by install.sh).
#   input: the current settings object
#   $frag: the fragment
# Objects are merged key by key, arrays are unioned (fragment items appended
# when missing), scalars are set only when absent. A value that is present
# and different is left alone and reported in .conflicts.
# Output: {doc, keys: [{path, value}], items: [{path, value}],
#          created: [path], conflicts: [{path, have, want}]}
# keys/items/created are what this run added, for the install manifest.

def leaves(p):
  if type == "object" and length > 0 then to_entries[] as $e | ($e.value | leaves(p + [$e.key]))
  else [p, .] end;

reduce ($frag | leaves([])) as [$p, $v]
  ({doc: ., keys: [], items: [], created: [], conflicts: []};
   # parent objects, created when absent
   (reduce range(1; $p | length) as $i (.;
      ($p[:$i]) as $q
      | if .bad then .
        elif (.doc | getpath($q)) == null then .doc |= setpath($q; {}) | .created += [$q]
        elif (.doc | getpath($q) | type) != "object" then
          .bad = true | .conflicts += [{path: $q, have: (.doc | getpath($q)), want: "an object"}]
        else . end))
   | if .bad then del(.bad)
     elif ($v | type) == "array" then
       (.doc | getpath($p)) as $cur
       | if $cur == null then .doc |= setpath($p; []) | .created += [$p]
         elif ($cur | type) != "array" then .conflicts += [{path: $p, have: $cur, want: $v}] | .skip = true
         else . end
       | if .skip then del(.skip)
         else reduce $v[] as $item (.;
           if any(.doc | getpath($p)[]; . == $item) then .
           else .doc |= setpath($p; getpath($p) + [$item]) | .items += [{path: $p, value: $item}] end)
         end
     else
       (.doc | getpath($p)) as $cur
       | if $cur == null then .doc |= setpath($p; $v) | .keys += [{path: $p, value: $v}]
         elif $cur == $v then .
         else .conflicts += [{path: $p, have: $cur, want: $v}] end
     end)
