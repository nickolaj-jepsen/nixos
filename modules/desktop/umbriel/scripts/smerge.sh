#!@shell@
# Merge can reuse a hidden window without asking Umbriel to reveal it.
if [[ -n "${UMBRIEL_SOCKET:-}" && $# == 1 && $1 != -* && -d $1 ]]; then
  id=$(umbriel windows --json 2>/dev/null | @jq@ -r '
    map(select(.app_id == "sublime_merge" and .scratchpad == "sublime-merge"))
    | sort_by([.active, .visible, .focused]) | last | .id // empty
  ')
  if [[ -n "$id" ]]; then
    umbriel msg window-focus "$id" >/dev/null 2>&1 || true
  fi
fi
exec @smerge@ "$@"
