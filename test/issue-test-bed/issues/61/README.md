# Issue #61 reproduction

Issue: [kubernetes-sigs/karpenter-provider-cluster-api#61](https://github.com/kubernetes-sigs/karpenter-provider-cluster-api/issues/61),
"Allow configuration to defer drift to Cluster API upgrade mechanisms".

## What it shows

Karpenter provisions workers by scaling a MachineDeployment; the provider then
labels the Machine it claimed `node.cluster.x-k8s.io/karpenter-member` and
binds it to a NodeClaim. When Cluster API itself upgrades that
MachineDeployment (a template rotation or a version bump), it replaces those
Machines with new ones from a new MachineSet. Nothing tells Karpenter.

`replicate.sh` runs that rollout and, every 15 seconds from just before it
starts until it has settled, checks the invariants that would hold if
Karpenter and Cluster API cooperated:

| | Invariant |
|---|---|
| I1 | every worker Machine carries the `karpenter-member` label |
| I2 | every worker Node is bound to a NodeClaim |
| I3 | no worker Node still has the `karpenter.sh/unregistered` taint |
| I4 | every NodeClaim points at a Machine that exists |
| I5 | every test pod is Running |
| I6 | once it has settled and the test pods are scaled to zero, Karpenter scales the pool back to zero: it can remove every worker, including the ones Cluster API created |

The issue is reproduced when any invariant breaks at any point during the
rollout. The damage is transient: in the first runs Karpenter lost every
NodeClaim, the replacement Nodes sat tainted and unusable, all test pods went
down, and then Karpenter recovered by claiming Cluster API's new Machines for
fresh NodeClaims. Without pending pods to trigger that, the new Machines stay
unclaimed for good: tainted, unusable, and never scaled down (I6). The end state looked healthy, so the verdict comes from the
whole timeline; `summary.txt` says how long each invariant stayed broken and
what the end state was, and whether Karpenter itself was available while
they were broken.

## Run it

From `test/issue-test-bed`:

```
make replicate-issue-61                                # TRIGGER=rollout-restart SCALE=3
make replicate-issue-61 TRIGGER=revision               # FROM=01-v1.34.8-v1.0 TO=02-v1.34.8-v1.1
```

`TRIGGER` picks how Cluster API replaces the workers:

| Trigger | What Cluster API does | Karpenter |
|---|---|---|
| `rollout-restart` (default) | sets the MachineDeployment's `rollout.after` (what `clusterctl alpha rollout restart` does): every worker is replaced through a new MachineSet, the control plane is not touched | stays where it is, on the control plane: the cleanest evidence |
| `revision` | deploys revision `TO` after `FROM` (both under `kubernetes/components/revisions/`); the default, a class rotation, rolls the control plane and the workers | moves with the control plane, and is unavailable while the new node starts its pod network (minutes on a single control plane node); the timeline records it |

It needs nothing set up first, and it can be run again and again:

- no clusters yet: `make clusters` runs first;
- Karpenter is built from the current commit and deployed
  (`make karpenter-release`), and the script refuses to start if the running
  pod is not that build;
- workers left from an earlier run are scaled away before it starts;
- `TRIGGER=revision` only: a workload cluster that is not at `FROM` (a
  previous run leaves it at `TO`) is recreated at `FROM` through Cluster API,
  keeping the management cluster (`RESET=0` refuses instead).

Exit status: 0 reproduced, 1 not reproduced, 2 preconditions not met, 3 failed
partway.

## Testing a fix

A run tests the provider code of the branch this test bed is checked out on:
`test/issue/61` (the bed plus this folder) is the baseline; a branch made
from it, with the fix commits cherry-picked, tests the fix.
`make replicate-issue-61` releases the current commit into Karpenter before
every run (tagged with the commit), and `summary.txt` records the image the
Karpenter pod ran (`karpenter running:`).

The NodeClass leaves `upgrades.managedBy` unset, so it applies with or without
the fix and the fix runs in its default `ClusterAPI` mode. To test `Karpenter`
mode, set it in `kubernetes/base/clusters/karpenter-docker/addons/nodeclass.yaml`,
and give Karpenter read access to MachineSets in
`kubernetes/base/clusters/karpenter-docker/karpenter-rbac.yaml`.

With adoption (`managedBy: ClusterAPI`), a replacement Machine is unclaimed
until it runs and is adopted, so I1 to I3 can still break briefly and the
script still reports the issue as reproduced. Judge a fix by `summary.txt`
instead: how long each invariant stayed broken against the baseline below,
and whether I6 passes.

| Run | Provider | I1 to I3 broken | I6 |
|---|---|---|---|
| 20261028T133546Z | main, no fix | about 120 to 135s | FAIL: Cluster API's Machines orphaned |
| 20261029T020600Z | adoption polling every 30s, 2m grace | about 210 to 225s | PASS in 51s |
| 20261030T022039Z | main: a stale pod, not the fix the branch carried | about 120 to 135s | PASS in 56s, after pending pods made the batcher claim the new Machines |

## Evidence

Every run writes `runs/<UTC time>/` next to the script, whatever its outcome.
The folder is gitignored (`issues/*/runs/`): attach a run to the issue or PR,
do not commit it.

| File | Content |
|---|---|
| `summary.txt` | result (or the step a failed run stopped at), which invariants broke during the rollout and for how long, the fewest pods Running at once, the end state, NodeClaims before and after, and the inputs: provider commit and uncommitted changes, Karpenter image ID, Cluster API version, tool versions, parameters, the command to rerun it |
| `run.log` | the whole console output of the run |
| `timeline.tsv` | every 15s from before the rollout: revision, replicas, Machines, members, MachineSets, NodeClaims, Ready and still-tainted Nodes, Running pods, Karpenter available, broken invariants |
| `00-leftover-before-start.txt`, `01-before.txt`, `02-during-*.txt`, `03-after.txt`, `04-after-scale-down.txt`, `99-at-failure.txt` | overview table, Machines, NodeClaims, Nodes with taints, pods |
| `invariants-before.txt`, `invariants-after.txt` | each invariant and what breaks it |
| `upgrade.log`, `karpenter.log`, `*-events.txt` | the rollout, Karpenter's log, events on both clusters |
