#!/usr/bin/env bash
# Everything this skill writes to Azure DevOps. Comment text is read from stdin.
#   pr-write.sh thread <prId> [--file </path> --line <n>] [--status active|closed]  < text   -> {"threadId": n}
#   pr-write.sh reply  <prId> <threadId>                                             < text
#   pr-write.sh status <prId> <threadId> active|fixed|byDesign|closed|wontFix
#   pr-write.sh vote   <prId> approved|approved-with-suggestions|waiting-for-author
# Without --file the thread is a general PR comment (used for the summary).
# There is deliberately no way to reject, abandon or edit the PR here.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
usage() { sed -n '2,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }
cmd="${1:-}"; shift || true
[[ $# -ge 1 ]] || usage
resolve_pr "$1"; shift
P="$PROJ_ENC/_apis/git/repositories/$REPO/pullRequests/$PR"

case "$cmd" in
  thread)
    file="" line="" status=active
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --file) file="$2"; shift 2 ;;
        --line) line="$2"; shift 2 ;;
        --status) status="$2"; shift 2 ;;
        *) usage ;;
      esac
    done
    [[ -z "$file" || "$line" =~ ^[0-9]+$ ]] || die "--file needs --line <n> (right side, new file)"
    body="$(python3 -I -c '
import json,sys
file,line,status=sys.argv[1:]; text=sys.stdin.read().strip()
if not text: sys.exit("empty comment text on stdin")
t={"comments":[{"parentCommentId":0,"content":text,"commentType":1}],"status":status}
if file:
    if not file.startswith("/"): file="/"+file
    t["threadContext"]={"filePath":file,"rightFileStart":{"line":int(line),"offset":1},"rightFileEnd":{"line":int(line),"offset":1}}
print(json.dumps(t))' "$file" "$line" "$status")"
    api POST "$P/threads" "$body" | python3 -I -c 'import json,sys; print(json.dumps({"threadId":json.load(sys.stdin)["id"]}))'
    ;;
  reply)
    tid="${1:?threadId}"
    body="$(python3 -I -c '
import json,sys; text=sys.stdin.read().strip()
if not text: sys.exit("empty comment text on stdin")
print(json.dumps({"parentCommentId":1,"content":text,"commentType":1}))')"
    api POST "$P/threads/$tid/comments" "$body" >/dev/null && echo '{"ok": true}'
    ;;
  status)
    tid="${1:?threadId}"; st="${2:?status}"
    case "$st" in active|fixed|byDesign|closed|wontFix|pending) ;; *) die "unknown status: $st" ;; esac
    api PATCH "$P/threads/$tid" "{\"status\":\"$st\"}" >/dev/null && echo '{"ok": true}'
    ;;
  vote)
    case "${1:-}" in
      approved) v=10 ;;
      approved-with-suggestions) v=5 ;;
      waiting-for-author) v=-5 ;;
      *) die "vote must be approved, approved-with-suggestions or waiting-for-author" ;;
    esac
    me="$(my_id)"
    # Keep the "required" flag the reviewer entry already has; a bare PUT would clear it.
    req="$(api GET "$P/reviewers" | python3 -I -c '
import json,sys; me=sys.argv[1]
print(json.dumps(any(r.get("isRequired") for r in json.load(sys.stdin)["value"] if r["id"]==me)))' "$me")"
    api PUT "$P/reviewers/$me" "{\"vote\":$v,\"isRequired\":$req}" >/dev/null && echo "{\"ok\": true, \"vote\": $v}"
    ;;
  *) usage ;;
esac
