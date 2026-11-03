#!/usr/bin/env bash
# Let the owner's agents deploy the Magpie hub unattended (run on Chicago, by the owner;
# agents may not change their own permissions). See README.md.
#
#   agent-allow.sh apply   add the two allow rules and point the daily duty at the wrapper
#   agent-allow.sh undo    remove the two rules and put the duty's old deploy step back
#
# Only those two things change; everything else in both files is left as it is.
set -euo pipefail
S=$HOME/.claude/settings.json
K=$HOME/.switchback/keeper.json
DUTY=6c6e20
A="Bash(ssh frankfurt 'sudo -n /usr/local/sbin/magpie-deploy')"
B="Bash(ssh frankfurt 'sudo -n -u magpie /opt/magpie/current/magpie-hubd status --home /var/lib/magpie')"
OLD="run magpie/deploy.sh on Frankfurt (it restarts the hub and rolls back if unhealthy); confirm 'sudo -n -u magpie /opt/magpie/current/magpie-hubd status --home /var/lib/magpie' shows the new version and folderErrors 0."
NEW="deploy by running exactly this command on its own (the owner allowed it; as ubuntu it builds, tests and stages HEAD of ~/code/magpie on Frankfurt, then restarts the hub, rolls back if unhealthy and prints the hub status): ssh frankfurt 'sudo -n /usr/local/sbin/magpie-deploy' . Then confirm with exactly: ssh frankfurt 'sudo -n -u magpie /opt/magpie/current/magpie-hubd status --home /var/lib/magpie' that it shows the new version and folderErrors 0. Don't run magpie/deploy.sh without arguments; if the wrapper command is refused, report that."

edit() { # edit <file> <jq program> [jq args...]
  local f=$1 prog=$2; shift 2
  jq "$@" "$prog" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}
duty_text() { jq -r --arg id "$DUTY" '.duties[] | select(.id == $id) | .what' "$K"; }
swap() { # swap <from> <to> in the duty's text
  duty_text | grep -qF "$1" || { echo "the duty's text doesn't have the expected deploy step; left as it is" >&2; return 1; }
  edit "$K" '(.duties[] | select(.id == $id) | .what) |= (split($from) | join($to))' --arg id "$DUTY" --arg from "$1" --arg to "$2"
}

case "${1:-}" in
  apply)
    for f in "$S" "$K"; do [[ -e $f.before-magpie-deploy ]] || cp -p "$f" "$f.before-magpie-deploy"; done
    edit "$S" '.permissions.allow = (((.permissions.allow // []) + [$a, $b]) | unique)' --arg a "$A" --arg b "$B"
    swap "$OLD" "$NEW" ;;
  undo)
    edit "$S" 'if .permissions.allow then .permissions.allow -= [$a, $b] else . end
      | if .permissions.allow == [] then del(.permissions.allow) else . end
      | if .permissions == {} then del(.permissions) else . end' --arg a "$A" --arg b "$B"
    swap "$NEW" "$OLD" ;;
  *) echo "usage: agent-allow.sh apply|undo" >&2; exit 2 ;;
esac
jq '.permissions' "$S"
duty_text
