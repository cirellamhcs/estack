#!/usr/bin/env bash
# Derive my review state for one PR from Azure DevOps itself (no local state).
# Usage: pr-state.sh <pullRequestId>            (or: pr-state.sh <project> <repositoryId> <pullRequestId>)   -> JSON
# state values:
#   skip-draft | skip-own | skip-inactive
#   new                    : I have never posted a "Reviewed <sha>" summary
#   up-to-date             : approved and head unchanged since my review
#   waiting-for-author     : my blocking threads are open, head unchanged, no new replies
#   needs-recheck          : head unchanged but my threads were replied to / resolved by others
#   changed-since-review   : author pushed since my last review (re-review the delta)
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
resolve_pr "$@"; proj="$PROJ_ENC"; repo="$REPO"; pr="$PR"
ME=$(api GET "_apis/connectionData?api-version=7.1-preview" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["authenticatedUser"]["id"])')
PRJ=$(api GET "$proj/_apis/git/repositories/$repo/pullRequests/$pr?includeWorkItemRefs=true")
THR=$(api GET "$proj/_apis/git/repositories/$repo/pullRequests/$pr/threads")
ITR=$(api GET "$proj/_apis/git/repositories/$repo/pullRequests/$pr/iterations")
PROJID=$(printf '%s' "$PRJ" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["repository"]["project"]["id"])')
POL=$(api GET "$proj/_apis/policy/evaluations?artifactId=vstfs:///CodeReview/CodeReviewId/$PROJID/$pr&api-version=7.1-preview.1" 2>/dev/null || echo '{"value":[]}')
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT; printf %s "$PRJ" >"$D/prj"; printf %s "$THR" >"$D/thr"; printf %s "$ITR" >"$D/itr"; printf %s "$POL" >"$D/pol"
python3 -I - "$ME" "$D" "$BASE_URL" <<'PY'
import json,sys,re
me=sys.argv[1]; base_url=sys.argv[3]; prj,thr,itr,pol=(json.load(open(sys.argv[2]+"/"+n)) for n in ("prj","thr","itr","pol"))
head=prj["lastMergeSourceCommit"]["commitId"]; base=prj["lastMergeTargetCommit"]["commitId"]
myvote=next((r["vote"] for r in prj.get("reviewers",[]) if r["id"]==me),None)
threads=[t for t in thr["value"] if not t.get("isDeleted")]
def text(t): return [c for c in t["comments"] if c.get("commentType")=="text" and not c.get("isDeleted")]
mine=[t for t in threads if text(t) and text(t)[0]["author"]["id"]==me]
reviewed=None; reviewed_at=""
for t in mine:
    c=text(t)[0]
    m=re.search(r"Reviewed\s+(?:head\s+)?([0-9a-f]{7,40})",c["content"])
    if m and c["publishedDate"]>=reviewed_at: reviewed,reviewed_at=m.group(1),c["publishedDate"]
author_id=prj["createdBy"]["id"]
def is_bot(a): return not a.get("uniqueName") or "copilot" in a.get("displayName","").lower()
def summarize(t):
    cs=text(t); ctx=t.get("threadContext") or {}
    return {"threadId":t["id"],"status":t.get("status"),"filePath":ctx.get("filePath"),
            "line":(ctx.get("rightFileStart") or {}).get("line"),
            "first":cs[0]["content"][:160],"openedByBot":is_bot(cs[0]["author"]),
            "lastAuthorIsMe":cs[-1]["author"]["id"]==me,"lastReplyIsPrAuthor":cs[-1]["author"]["id"]==author_id,
            "replies":len(cs)-1}
my_inline=[summarize(t) for t in mine if (t.get("threadContext") or {}).get("filePath")]
open_mine=[t for t in my_inline if t["status"] in ("active","pending")]
replied=[t for t in my_inline if not t["lastAuthorIsMe"]]
resolved_by_other=[t for t in my_inline if t["status"] in ("fixed","closed","wontFix","byDesign") and not t["lastAuthorIsMe"]]
# Build validation (the pipeline runs build and tests; this skill only reads the result).
builds=[]
for e in pol.get("value",[]):
    c=e["configuration"]
    if c["type"]["displayName"]!="Build": continue
    x=e.get("context") or {}; prev=(x.get("buildOutputPreview") or {})
    builds.append({"pipeline":x.get("buildDefinitionName") or c.get("settings",{}).get("displayName"),
        "status":e.get("status"),"blocking":c.get("isBlocking"),
        "ranOnHead":x.get("lastMergeSourceCommitId")==head,
        "targetMovedSince":bool(x.get("buildIsNotCurrent")),
        "expired":bool(x.get("isExpired")),
        "url":f'{base_url}/{prj["repository"]["project"]["name"].replace(" ","%20")}/_build/results?buildId={x["buildId"]}' if x.get("buildId") else None,
        "errors":[m.get("message","")[:300] for m in (prev.get("errors") or [])][:10]})
others_open=[summarize(t) for t in threads if text(t) and text(t)[0]["author"]["id"]!=me and (t.get("threadContext") or {}).get("filePath") and t.get("status") in ("active","pending")]
if prj.get("isDraft"): state="skip-draft"
elif prj["createdBy"]["id"]==me: state="skip-own"
elif prj["status"]!="active": state="skip-inactive"
elif reviewed is None: state="new"
elif not head.startswith(reviewed): state="changed-since-review"
elif myvote in (10,5): state="up-to-date"
elif replied or resolved_by_other: state="needs-recheck"
elif open_mine: state="waiting-for-author"
else: state="needs-recheck"
print(json.dumps({
 "pullRequestId":prj["pullRequestId"],"project":prj["repository"]["project"]["name"],
 "repository":prj["repository"]["name"],"repositoryId":prj["repository"]["id"],
 "title":prj["title"],"description":prj.get("description",""),"isDraft":prj.get("isDraft",False),"authorIsMe":prj["createdBy"]["id"]==me,
 "reviewerVotes":sorted(r["vote"] for r in prj.get("reviewers",[]) if r["id"]!=me),
 "sourceRef":prj["sourceRefName"],"targetRef":prj["targetRefName"],"head":head,"base":base,
 "mergeStatus":prj.get("mergeStatus"),"autoComplete":bool(prj.get("autoCompleteSetBy")),
 "workItems":[w["id"] for w in prj.get("workItemRefs",[])],
 "iterations":len(itr["value"]),"lastPush":itr["value"][-1]["createdDate"] if itr["value"] else None,
 "me":me,"myVote":myvote,"myReviewedHead":reviewed,"myReviewedAt":reviewed_at or None,
 "myInlineThreads":my_inline,"otherOpenThreads":others_open,
 "policies":sorted({(e["configuration"]["type"]["displayName"],e.get("status")) for e in pol.get("value",[]) if e["configuration"]["type"]["displayName"]!="Build"}),
 "builds":builds,
 "state":state},indent=1))
PY
