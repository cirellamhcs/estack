#!/usr/bin/env bash
# List active PRs where I am a reviewer, org-wide, with my vote and a triage hint.
# Usage: list-prs.sh            -> JSON array
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ME=$(api GET "_apis/connectionData?api-version=7.1-preview" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["authenticatedUser"]["id"])')
# Org-wide query across all projects: ADO supports $filter on reviewerId at project scope only, so iterate projects.
api GET "_apis/projects?%24top=200" | python3 -I -c 'import json,sys; [print(p["name"]) for p in json.load(sys.stdin)["value"]]' | while IFS= read -r proj; do
  pe=$(urlenc "$proj")
  api GET "$pe/_apis/git/pullrequests?searchCriteria.status=active&searchCriteria.reviewerId=$ME&%24top=200" 2>/dev/null || echo '{"value":[]}'
done | python3 -I -c '
import json,sys,datetime
me=sys.argv[1]; out=[]
dec=json.JSONDecoder(); buf=sys.stdin.read(); i=0
while i < len(buf):
    while i < len(buf) and buf[i].isspace(): i+=1
    if i>=len(buf): break
    obj,j=dec.raw_decode(buf,i); i=j
    for pr in obj.get("value",[]):
        mine=[r for r in pr.get("reviewers",[]) if r["id"]==me]
        vote=mine[0]["vote"] if mine else None
        created=datetime.datetime.fromisoformat(pr["creationDate"].replace("Z","+00:00"))
        age=(datetime.datetime.now(datetime.timezone.utc)-created).days
        out.append({
          "pullRequestId":pr["pullRequestId"],"project":pr["repository"]["project"]["name"],
          "repository":pr["repository"]["name"],"repositoryId":pr["repository"]["id"],
          "title":pr["title"],"authorId":pr["createdBy"]["id"],"isDraft":pr.get("isDraft",False),
          "created":pr["creationDate"][:10],"ageDays":age,"myVote":vote,
          "head":pr.get("lastMergeSourceCommit",{}).get("commitId"),
          "triage":("skip-draft" if pr.get("isDraft") else "skip-own" if pr["createdBy"]["id"]==me else "stale" if age>90 else "review")})
out.sort(key=lambda p:-p["pullRequestId"])
print(json.dumps(out,indent=1))' "$ME"
