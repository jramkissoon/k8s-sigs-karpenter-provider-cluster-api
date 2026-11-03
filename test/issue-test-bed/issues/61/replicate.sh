#!/usr/bin/env bash
# Reproduce issue #61: a Cluster API rollout of a MachineDeployment whose
# Machines Karpenter provisioned leaves Karpenter and Cluster API disagreeing
# about the workers.
#
# Starts with SCALE Karpenter-provisioned workers, has Cluster API replace
# every one of them, and, every SAMPLE seconds from just before that until it
# has settled, checks the invariants that hold when the two cooperate:
#   I1 every worker Machine carries the karpenter-member label
#   I2 every worker Node is bound to a NodeClaim
#   I3 no worker Node still has the karpenter.sh/unregistered taint
#   I4 every NodeClaim points at a Machine that exists
#   I5 every test pod is Running
# and, once the rollout has settled and the test pods are scaled to zero:
#   I6 Karpenter scales the pool back to zero (it can remove every worker,
#      including the ones Cluster API created)
# The issue is reproduced when any of them breaks at any point: the damage is
# transient (Karpenter can later adopt Cluster API's new Machines by accident),
# so the end state alone does not show it. How long each stayed broken, the
# end state, and whether Karpenter itself was available are recorded too.
#
# TRIGGER picks how Cluster API replaces the workers:
#   rollout-restart (default)  the MachineDeployment's rollout.after: only the
#                              workers roll, Karpenter (on the control plane)
#                              never moves; works at any revision
#   revision                   the revision step FROM -> TO (a class rotation by
#                              default): a full upgrade, control plane included,
#                              so Karpenter moves with it
#
# Reproducible: with TRIGGER=revision a workload cluster that is not at FROM (a
# previous run leaves it at TO) is recreated at FROM first, through Cluster API;
# the management cluster is kept. RESET=0 refuses instead.
#
# Every run, whatever its outcome, writes runs/<UTC time>/ next to this script,
# with summary.txt
# (result, the step it stopped at, inputs, how to rerun) and run.log.
# Exit 0 reproduced, 1 not reproduced, 2 preconditions not met, 3 failed.
# The cluster is left as the run left it, for inspection.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTBED="$(cd "$HERE/../.." && pwd)"
TRIGGER="${TRIGGER:-rollout-restart}"
FROM="${FROM:-01-v1.34.8-v1.0}"
TO="${TO:-02-v1.34.8-v1.1}"
SCALE="${SCALE:-3}"
SAMPLE="${SAMPLE:-15}"          # seconds between timeline samples
SETTLE="${SETTLE:-180}"         # seconds to keep watching after the rollout finishes
TIMEOUT="${TIMEOUT:-1500}"      # seconds before giving up on the rollout
RESET="${RESET:-1}"             # recreate the workload cluster at FROM when it is elsewhere

CLUSTER="$(make -s -C "$TESTBED" print-WL_CLUSTER_NAME)"
NS="$CLUSTER"
export PATH="$TESTBED/hack/tools/bin:$PATH"
MGMT=(kubectl --kubeconfig "$TESTBED/kubeconfig/capi-karpenter-test.kubeconfig")
WL=(kubectl --kubeconfig "$TESTBED/kubeconfig/$CLUSTER.kubeconfig")
MEMBER="node.cluster.x-k8s.io/karpenter-member"
WORKERS="cluster.x-k8s.io/cluster-name=$CLUSTER,!cluster.x-k8s.io/control-plane"
# Evidence sits next to the script, in runs/ (gitignored: issues/*/runs/).
RUN="$HERE/runs/$(date -u +%Y%m%dT%H%M%SZ)"
case "$TRIGGER" in
  rollout-restart) RERUN="make replicate-issue-61 TRIGGER=rollout-restart SCALE=$SCALE SAMPLE=$SAMPLE SETTLE=$SETTLE" ;;
  revision)        RERUN="make replicate-issue-61 TRIGGER=revision FROM=$FROM TO=$TO SCALE=$SCALE SAMPLE=$SAMPLE SETTLE=$SETTLE" ;;
  *) echo "TRIGGER must be rollout-restart or revision, not '$TRIGGER'" >&2; exit 2 ;;
esac

mkdir -p "$RUN"
exec > >(tee -a "$RUN/run.log") 2>&1

STEP="start"; RESULT=""; BROKEN=""; DURING=""; ROLLED=""; SURVIVED=""; RESETS=""; LEFTOVER=""; SCALEDOWN=""; SAMPLER_PID=""
SCALEDOWN_TIMEOUT="${SCALEDOWN_TIMEOUT:-300}"   # seconds Karpenter gets to remove every worker (I6)
log() { STEP="$*"; printf '\n==> %s\n' "$*"; }

# wait_for <seconds> <description> <expression>: poll until the single-quoted
# shell expression succeeds; it is re-evaluated on every iteration.
wait_for() {
  local deadline=$(( $(date +%s) + $1 )) what=$2 expr=$3
  until eval "$expr"; do
    if (( $(date +%s) >= deadline )); then echo "timed out waiting for: $what" >&2; return 1; fi
    sleep 5
  done
}

# --- Observations ---------------------------------------------------------------

revision() { "${MGMT[@]}" get -n "$NS" "cluster/$CLUSTER" -o jsonpath='{.metadata.labels.test-bed/revision}' 2>/dev/null; }

# <machine> <machineset> <member yes/-> <phase> <node>, one worker Machine per line.
worker_machines() {
  "${MGMT[@]}" get machines -n "$NS" -l "$WORKERS" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.labels.cluster\.x-k8s\.io/set-name}{"\t"}{.metadata.labels}{"\t"}{.status.phase}{"\t"}{.status.nodeRef.name}{"\n"}{end}' 2>/dev/null \
    | awk -F'\t' -v m="$MEMBER" '{ member = index($3, "\"" m "\"") ? "yes" : "-"; print $1 "\t" $2 "\t" member "\t" $4 "\t" ($5 == "" ? "-" : $5) }'
}

# <nodeclaim> <providerID> <node>, one per line.
nodeclaims() {
  "${WL[@]}" get nodeclaims -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.providerID}{"\t"}{.status.nodeName}{"\n"}{end}' 2>/dev/null \
    | awk -F'\t' '{ print $1 "\t" ($2 == "" ? "-" : $2) "\t" ($3 == "" ? "-" : $3) }'
}

# <node> <Ready status> <taint keys>, workers only (not the control plane).
worker_nodes() {
  "${WL[@]}" get nodes -l '!node-role.kubernetes.io/control-plane' \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\t"}{.spec.taints[*].key}{"\n"}{end}' 2>/dev/null \
    | awk -F'\t' '{ print $1 "\t" $2 "\t" ($3 == "" ? "-" : $3) }'
}

scale_up_pods() { "${WL[@]}" get pods -l app=scale-up -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\t"}{.spec.nodeName}{"\n"}{end}' 2>/dev/null; }
md_replicas()   { "${MGMT[@]}" get md -n "$NS" -l "cluster.x-k8s.io/cluster-name=$CLUSTER" -o jsonpath='{.items[0].spec.replicas}' 2>/dev/null; }
machinesets()   { worker_machines | cut -f2 | sort -u | tr '\n' ' '; }
karpenter_up()  { [ "$("${WL[@]}" get deploy -n karpenter karpenter -o jsonpath='{.status.availableReplicas}' 2>/dev/null)" -ge 1 ] 2>/dev/null && echo up || echo DOWN; }
running_pods()  { scale_up_pods | awk -F'\t' '$2 == "Running"' | grep -c . || true; }
bound_claims()  { nodeclaims | awk -F'\t' '$3 != "-"' | grep -c . || true; }

# snapshot <name>: everything needed to explain a moment of the run.
snapshot() {
  local f="$RUN/$1.txt"
  {
    echo "# $1 at $(date -u +%H:%M:%SZ), revision $(revision), MachineDeployment replicas $(md_replicas)"
    echo; echo "## overview"; make -s -C "$TESTBED" overview 2>/dev/null | grep -v ' ready$'
    echo; echo "## worker Machines: name, machineset, karpenter-member, phase, node"; worker_machines
    echo; echo "## NodeClaims: name, providerID, node"; nodeclaims
    echo; echo "## worker Nodes: name, Ready, taints"; worker_nodes
    echo; echo "## scale-up pods: name, phase, node"; scale_up_pods
  } > "$f" 2>/dev/null || true
}

timeline_header() { printf 'time\trevision\tmd_replicas\tmachines\tmembers\tmachinesets\tnodeclaims\tnodes_ready\tnodes_unregistered\tpods_running\tkarpenter\tbroken\n' > "$RUN/timeline.tsv"; }
timeline_sample() {
  local m n broken
  m=$(worker_machines); n=$(worker_nodes)
  broken=$(check_invariants 2>/dev/null | awk '$1 == "FAIL" { print $2 }' | paste -sd, -)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%H:%M:%S)" "$(revision)" "$(md_replicas)" \
    "$(grep -c . <<<"$m" || true)" "$(awk -F'\t' '$3 == "yes"' <<<"$m" | grep -c . || true)" "$(machinesets)" \
    "$(nodeclaims | grep -c . || true)" "$(awk -F'\t' '$2 == "True"' <<<"$n" | grep -c . || true)" \
    "$(grep -c 'karpenter.sh/unregistered' <<<"$n" || true)" "$(running_pods)" "$(karpenter_up)" "${broken:--}" \
    | tee -a "$RUN/timeline.tsv" | column -t -s $'\t'
}

# sampler: sample the timeline every SAMPLE seconds, with a full snapshot every
# fourth sample, until $RUN/.stop exists. Runs in the background so the
# rollout is watched from before `make upgrade` starts.
sampler() {
  local n=0
  until [ -e "$RUN/.stop" ]; do
    timeline_sample || true; n=$((n + 1))
    if (( n % 4 == 0 )); then snapshot "02-during-$(printf '%03d' "$n")"; fi
    sleep "$SAMPLE"
  done
}

# breakage: from the timeline, each invariant that broke and for how long.
breakage() {
  awk -F'\t' -v s="$SAMPLE" 'NR > 1 && $12 != "-" {
      n = split($12, ids, ","); for (i = 1; i <= n; i++) { if (!(ids[i] in first)) first[ids[i]] = $1; count[ids[i]]++ }
      broken++; if ($11 != "up") overlap++
    }
    NR > 1 { samples++; if ($11 != "up") down++ }
    NR > 1 && (min == "" || $10 + 0 < min) { min = $10 + 0 }
    END {
      for (id in count) printf "  %s broken in %d sample(s), about %ds, first at %s\n", id, count[id], count[id] * s, first[id] | "sort"
      close("sort"); printf "  fewest scale-up pods Running at once: %s\n", min
      printf "  Karpenter available in %d of %d samples; down in %d of the %d samples with a broken invariant\n", samples - down, samples, overlap, broken
    }' "$RUN/timeline.tsv"
}

# --- Invariants --------------------------------------------------------------------

# check_invariants: print each invariant with the objects that break it; return
# the number broken.
check_invariants() {
  local m n c p broken=0 bad running
  m=$(worker_machines); n=$(worker_nodes); c=$(nodeclaims); p=$(scale_up_pods)
  report() { if [ -z "$2" ]; then echo "  PASS $1"; else echo "  FAIL $1"; sed 's/^/         /' <<<"$2"; broken=$((broken + 1)); fi; }

  bad=$(awk -F'\t' '$3 != "yes" { print $1 " (machineset " $2 ")" }' <<<"$m")
  report "I1 every worker Machine carries $MEMBER" "$bad"

  bad=$(awk -F'\t' 'NR == FNR { if ($3 != "-") bound[$3] = 1; next } !($1 in bound) { print $1 }' <(echo "$c") <(echo "$n"))
  report "I2 every worker Node is bound to a NodeClaim" "$bad"

  bad=$(awk -F'\t' '$3 ~ /karpenter.sh\/unregistered/ { print $1 " (taints: " $3 ")" }' <<<"$n")
  report "I3 no worker Node still has the karpenter.sh/unregistered taint" "$bad"

  bad=$(awk -F'\t' 'NR == FNR { have["docker:////" $1] = 1; next } $2 != "-" && !($2 in have) { print $1 " -> " $2 }' <(echo "$m") <(echo "$c"))
  report "I4 every NodeClaim points at a Machine that exists" "$bad"

  running=$(awk -F'\t' '$2 == "Running"' <<<"$p" | grep -c . || true)
  bad=$(awk -F'\t' '$2 != "Running" { print $1 " (" $2 ")" }' <<<"$p")
  [ "$running" = "$SCALE" ] || bad="${bad:+$bad$'\n'}$running of $SCALE pods Running"
  report "I5 all $SCALE scale-up pods are Running" "$bad"
  return "$broken"
}

# --- Summary, written on every exit ------------------------------------------------

# Inputs that produced this run, so it can be compared with and repeated.
inputs() {
  local commit dirty image capi
  commit=$(git -C "$TESTBED" rev-parse HEAD 2>/dev/null || echo unknown)
  dirty=$(git -C "$TESTBED/../.." status --porcelain -- . ':!test/issue-test-bed/issues/*/runs' 2>/dev/null | grep -c . || true)
  image=$(docker image inspect "$(make -s -C "$TESTBED" print-KARPENTER_IMAGE)" -f '{{.Id}}' 2>/dev/null || echo unknown)
  capi=$(awk '/^  version:/ { print $2; exit }' "$TESTBED/kubernetes/base/clusters/management/capi-providers/providers.yaml" 2>/dev/null)
  echo "provider commit:    $commit$( [ "$dirty" -gt 0 ] && echo " + $dirty uncommitted change(s)")"
  echo "branch:             $(git -C "$TESTBED" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  echo "karpenter image:    $(make -s -C "$TESTBED" print-KARPENTER_IMAGE) ($image)"
  echo "karpenter running:  $(make -s -C "$TESTBED" karpenter-check 2>/dev/null | tail -1)"
  echo "cluster api:        $capi (CAPD), cluster $CLUSTER from a ClusterClass"
  case "$TRIGGER" in
    rollout-restart) echo "rollout:            rollout restart of the worker MachineDeployment (control plane untouched), $SCALE Karpenter-provisioned workers" ;;
    revision)        echo "rollout:            revision $FROM -> $TO (control plane and workers), $SCALE Karpenter-provisioned workers" ;;
  esac
  echo "parameters:         TRIGGER=$TRIGGER SAMPLE=$SAMPLE SETTLE=$SETTLE TIMEOUT=$TIMEOUT RESET=$RESET"
  echo "tools:              $(make -s -C "$TESTBED" tools-list 2>/dev/null | awk '{ printf "%s %s, ", $1, $2 }' | sed 's/, $//')"
  echo "rerun:              $RERUN"
}

finish() {
  local status=$? failed=""
  set +e
  touch "$RUN/.stop" 2>/dev/null; [ -n "${SAMPLER_PID:-}" ] && wait "$SAMPLER_PID" 2>/dev/null; rm -f "$RUN/.stop"
  if [ -z "$RESULT" ]; then
    RESULT="FAILED during: $STEP (exit $status)"; failed=1
    [ -f "$TESTBED/kubeconfig/$CLUSTER.kubeconfig" ] && snapshot 99-at-failure
  fi
  {
    echo "karpenter-provider-cluster-api issue #61 reproduction, $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "result:             $RESULT"
    [ -n "$RESETS" ]   && echo "reset:              $RESETS"
    [ -n "$LEFTOVER" ] && echo "before the run:     $LEFTOVER"
    [ -n "$ROLLED" ]   && echo "rollout finished:   $ROLLED"
    [ -n "$SURVIVED" ] && echo "NodeClaims:         $SURVIVED"
    [ -n "$DURING" ]   && echo "during the rollout: $DURING"
    [ -n "$BROKEN" ]   && echo "at the end:         $BROKEN of 5 invariants broken"
    [ -n "$SCALEDOWN" ] && echo "scale down (I6):    $SCALEDOWN"
    if [ -s "$RUN/timeline.tsv" ] && [ "$(wc -l < "$RUN/timeline.tsv")" -gt 1 ]; then echo; echo "breakage over the rollout:"; breakage; fi
    echo
    inputs
    if [ -f "$RUN/invariants-after.txt" ]; then echo; echo "invariants after the rollout:"; cat "$RUN/invariants-after.txt"; fi
  } > "$RUN/summary.txt"
  printf '\n==> Summary\n'; cat "$RUN/summary.txt"
  echo; echo "evidence: $RUN"; ls -1 "$RUN" | sed 's/^/  /'
  sleep 1   # let the tee behind run.log drain before the shell exits
  [ -z "$failed" ] || exit 3
}
trap finish EXIT

# --- Run ---------------------------------------------------------------------------

echo "issue #61 reproduction; evidence in $RUN"

log "Preconditions"
if [ ! -f "$TESTBED/kubeconfig/$CLUSTER.kubeconfig" ]; then
  RESULT="PRECONDITION: no $CLUSTER cluster; run 'make replicate-issue-61' (it builds the clusters) or 'make clusters'"
  echo "$RESULT" >&2; exit 2
fi
# A run must test the checked-out code: Karpenter keeps running its old image
# until it restarts, whatever was built or imported since.
# (pipefail keeps karpenter-check's status; its verdict is the last line)
if ! running=$(make -s -C "$TESTBED" karpenter-check 2>/dev/null | tail -1); then
  RESULT="PRECONDITION: $running; run 'make replicate-issue-61' (it releases the current commit) or 'make karpenter-release'"
  echo "$RESULT" >&2; exit 2
fi
echo "$running"
current=$(revision || true)
if [ "$TRIGGER" = revision ] && [ "$current" != "$FROM" ]; then
  if [ "$RESET" != 1 ]; then
    RESULT="PRECONDITION: $CLUSTER is at '${current:-<none>}', not $FROM, and RESET=0"
    echo "$RESULT" >&2; exit 2
  fi
  log "Recreating $CLUSTER at $FROM (it is at '${current:-<none>}')"
  RESETS="workload cluster recreated: was at '${current:-<none>}'"
  make -s -C "$TESTBED" wl-down
  make -s -C "$TESTBED" clusters REVISION="$FROM"
  current=$(revision)
  [ "$current" = "$FROM" ] || { RESULT="PRECONDITION: recreated $CLUSTER is at '$current', not $FROM"; exit 2; }
fi
existing=$(nodeclaims | grep -c . || true)
if [ "$existing" != 0 ] || [ "$(md_replicas)" != 0 ]; then
  log "Scaling to zero first ($existing NodeClaims, MachineDeployment replicas $(md_replicas))"
  make -s -C "$TESTBED" workloads-down >/dev/null 2>&1 || true
  if ! wait_for 300 "Karpenter to scale the pool to zero" '[ "$(nodeclaims | grep -c . || true)" = 0 ] && [ "$(md_replicas)" = 0 ]'; then
    # Workers Karpenter does not own (left by an earlier Cluster API rollout)
    # are invisible to it, so it cannot remove them: that is the issue too.
    snapshot 00-leftover-before-start
    LEFTOVER="$(worker_machines | grep -c . || true) worker Machine(s) Karpenter could not remove (MachineDeployment replicas $(md_replicas), $(nodeclaims | grep -c . || true) NodeClaims); scaled the MachineDeployment to 0 by hand, see 00-leftover-before-start.txt"
    echo "$LEFTOVER"
    "${MGMT[@]}" scale machinedeployment -n "$NS" "$("${MGMT[@]}" get md -n "$NS" -l "cluster.x-k8s.io/cluster-name=$CLUSTER" -o jsonpath='{.items[0].metadata.name}')" --replicas=0 >/dev/null
    wait_for 600 "no NodeClaims and zero replicas" '[ "$(nodeclaims | grep -c . || true)" = 0 ] && [ "$(md_replicas)" = 0 ]'
  fi
fi
wait_for 600 "no worker Machines left" '[ -z "$(worker_machines)" ]'
echo "cluster $CLUSTER at $(revision) with no workers"

log "Karpenter provisions $SCALE workers"
make -s -C "$TESTBED" workloads SCALE_UP_REPLICAS="$SCALE" >/dev/null
wait_for 900 "$SCALE Running scale-up pods" '[ "$(running_pods)" = "$SCALE" ]'
wait_for 300 "$SCALE NodeClaims bound to Nodes" '[ "$(bound_claims)" = "$SCALE" ]'
snapshot 01-before
log "Invariants before the rollout (all must pass)"
if ! check_invariants | tee "$RUN/invariants-before.txt"; then
  RESULT="PRECONDITION: invariants already broken before the rollout; see invariants-before.txt"; exit 2
fi
nodeclaims | cut -f1 | sort > "$RUN/nodeclaims-before.txt"
before_sets=$(machinesets)

log "Sampling every ${SAMPLE}s from before the rollout"
timeline_header; column -t -s $'\t' "$RUN/timeline.tsv"
sampler & SAMPLER_PID=$!
sleep "$SAMPLE"

if [ "$TRIGGER" = rollout-restart ]; then
  log "Cluster API rollout: rollout restart of the worker MachineDeployment"
  make -s -C "$TESTBED" rollout-restart 2>&1 | grep -v ' ready$' | tee "$RUN/upgrade.log"
else
  log "Cluster API rollout: $FROM -> $TO"
  make -s -C "$TESTBED" upgrade TO="$TO" 2>&1 | grep -v ' ready$' | tee "$RUN/upgrade.log"
fi

log "Waiting until no worker Machine is left in [$before_sets], then ${SETTLE}s more"
deadline=$(( $(date +%s) + TIMEOUT )); settle_until=0
while (( $(date +%s) < deadline )); do
  if [ -z "$ROLLED" ]; then
    left=$(worker_machines | awk -F'\t' -v old=" $before_sets" 'index(old, " " $2 " ")' | grep -c . || true)
    new=$(worker_machines | awk -F'\t' -v old=" $before_sets" '!index(old, " " $2 " ") && $4 == "Running"' | grep -c . || true)
    if [ "$left" = 0 ] && [ "$new" -ge 1 ]; then
      ROLLED=$(date -u +%H:%M:%SZ); settle_until=$(( $(date +%s) + SETTLE ))
      echo "-- rollout finished at $ROLLED; settling ${SETTLE}s"
    fi
  elif (( $(date +%s) >= settle_until )); then break; fi
  sleep "$SAMPLE"
done
[ -n "$ROLLED" ] || { ROLLED="no, timed out after ${TIMEOUT}s"; echo "-- rollout did not finish; checking the state it reached"; }
touch "$RUN/.stop"; wait "$SAMPLER_PID" 2>/dev/null || true; rm -f "$RUN/.stop"; SAMPLER_PID=""

log "Collecting evidence"
snapshot 03-after
"${WL[@]}" logs -n karpenter deploy/karpenter --since=60m > "$RUN/karpenter.log" 2>&1 || true
"${WL[@]}" get events -A --sort-by=.lastTimestamp > "$RUN/workload-events.txt" 2>&1 || true
"${MGMT[@]}" get events -n "$NS" --sort-by=.lastTimestamp > "$RUN/management-events.txt" 2>&1 || true
nodeclaims | cut -f1 | sort > "$RUN/nodeclaims-after.txt"
SURVIVED="$(grep -c . "$RUN/nodeclaims-before.txt" || true) before the rollout, $(comm -12 "$RUN/nodeclaims-before.txt" "$RUN/nodeclaims-after.txt" | grep -c . || true) of them still present after"

log "Invariants at the end"
set +e; check_invariants | tee "$RUN/invariants-after.txt"; BROKEN=${PIPESTATUS[0]}; set -e

log "I6: scaling the test pods to zero; Karpenter has ${SCALEDOWN_TIMEOUT}s to remove every worker"
make -s -C "$TESTBED" workloads-down >/dev/null 2>&1 || true
start=$(date +%s)
if wait_for "$SCALEDOWN_TIMEOUT" "every worker removed" '[ -z "$(worker_machines)" ] && [ "$(md_replicas)" = 0 ]'; then
  SCALEDOWN="PASS, Karpenter removed every worker in $(( $(date +%s) - start ))s"; I6=""
else
  snapshot 04-after-scale-down
  SCALEDOWN="FAIL, after ${SCALEDOWN_TIMEOUT}s $(worker_machines | grep -c . || true) worker Machine(s) remain ($(worker_machines | awk -F'\t' '$3 != "yes"' | grep -c . || true) not Karpenter's), MachineDeployment replicas $(md_replicas), $(nodeclaims | grep -c . || true) NodeClaims; see 04-after-scale-down.txt"
  I6="I6"
fi
echo "$SCALEDOWN"
during=$( { awk -F'\t' 'NR > 1 && $12 != "-" { n = split($12, ids, ","); for (i = 1; i <= n; i++) seen[ids[i]] = 1 } END { for (id in seen) printf "%s ", id }' "$RUN/timeline.tsv"; echo "${I6:-}"; } | tr ' ' '\n' | grep . | sort | paste -sd, -)
DURING="${during:-none} broken at some point"
if [ -n "$during" ]; then
  RESULT="ISSUE REPRODUCED: during the Cluster API rollout invariants $during broke (Karpenter and Cluster API disagreed about the workers)"
  exit 0
fi
RESULT="NOT REPRODUCED: every invariant held throughout the rollout"
exit 1
