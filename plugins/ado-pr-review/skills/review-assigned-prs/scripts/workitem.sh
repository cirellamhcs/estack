#!/usr/bin/env bash
# Show a work item as plain text JSON (title, type, state, description, acceptance criteria).
# Usage: workitem.sh <id> [<id> ...]
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[[ $# -ge 1 ]] || { echo "usage: workitem.sh <id> [<id> ...]" >&2; exit 2; }
ids="$(IFS=,; echo "$*")"
api GET "_apis/wit/workitems?ids=$ids&\$expand=relations" | python3 -I -c '
import json,sys,re,html
def plain(s): return html.unescape(re.sub(r"<[^>]+>"," ",re.sub(r"<br\s*/?>|</(p|div|li)>","\n",s or ""))).strip()
out=[]
for w in json.load(sys.stdin)["value"]:
    f=w["fields"]
    out.append({"id":w["id"],"type":f.get("System.WorkItemType"),"state":f.get("System.State"),"title":f.get("System.Title"),
                "description":plain(f.get("System.Description")),
                "acceptanceCriteria":plain(f.get("Microsoft.VSTS.Common.AcceptanceCriteria")),
                "related":[r["url"].rsplit("/",1)[-1] for r in w.get("relations") or [] if "workItems" in r.get("url","")]})
print(json.dumps(out,indent=1))'
