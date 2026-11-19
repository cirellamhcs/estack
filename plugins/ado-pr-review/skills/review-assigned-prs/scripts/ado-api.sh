#!/usr/bin/env bash
# Raw Azure DevOps REST call. Usage: ado-api.sh METHOD PATH [JSON_BODY]
# Example: ado-api.sh GET "My%20Project/_apis/git/repositories/<repoId>/pullRequests/<id>/iterations"
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
api "$@"
