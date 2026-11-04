set -euo pipefail

# Reads one request from the socket sshd forwarded here — "host<TAB>path<TAB>line<TAB>col",
# written by editor-open on the other host (see ./editor-open.bash) — and opens that host's
# path in this machine's editor, which reaches it through its own ssh support. One
# connection per request, from the user socket editor-open-bridge.socket. `ok` on the socket
# answers the caller; anything else and it falls back to nvim.
#
# Only the hosts named below may ask: the editor would ssh to whatever it is told, with this
# machine's keys.
hosts='@bridgeHosts@'

host=""
path=""
line=""
col=""
# Tab-separated, and a field may be empty: read one delimiter at a time so `col` without
# `line` does not shift into it. A connection that says nothing must not hold an instance.
IFS= read -r -t 5 -d $'\t' host || true
IFS= read -r -t 5 -d $'\t' path || true
IFS= read -r -t 5 -d $'\t' line || true
IFS= read -r -t 5 col || true

known=false
for alias in $hosts; do
  if [[ $host == "$alias" ]]; then
    known=true
    break
  fi
done

if [[ $known == false || $path != /* ]]; then
  echo "editor-open-bridge: not a request from a bridge host: host='$host' path='$path'" >&2
  exit 1
fi
# A position is a number or nothing; the wire format leaves room for both to be empty.
[[ $line =~ ^[0-9]+$ ]] || line=""
[[ $col =~ ^[0-9]+$ ]] || col=""

position=()
if [[ -n $line ]]; then
  position+=(--line "$line")
  [[ -n $col ]] && position+=(--col "$col")
fi

# The editor's own output belongs in the journal: the socket carries only the answer.
if ! editor-open --remote "$host" "${position[@]}" "$path" 1>&2; then
  echo "editor-open-bridge: could not open $path on $host" >&2
  exit 1
fi
echo ok
