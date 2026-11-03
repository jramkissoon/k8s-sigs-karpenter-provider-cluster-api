# Issue test bed

A local Cluster API + Karpenter environment on Docker, for reproducing issues
in the provider and testing their fixes. Karpenter is built from this branch (the checkout two directories up), so what
runs is the code being changed.

A kind cluster is the **management** cluster: cert-manager, the Cluster API
Operator, Cluster API and its Docker provider (CAPD). CAPD creates one
**workload** cluster, `karpenter-docker`, from a ClusterClass. Karpenter runs
inside the workload cluster and scales its worker MachineDeployment.

## Layout

```
Makefile                 every task; `make help` lists them
kind-config.yaml         the management cluster (kind)

kubernetes/              every Kubernetes manifest
  overlays/dev/            WHAT GETS DEPLOYED
    clusters/
      management/            to the management cluster: the base plus ONE
                             revision component (rewritten by `make deploy`)
      karpenter-docker/      inside the workload cluster: Calico, Karpenter,
                             NodeClass, NodePool
    workloads/               inside the workload cluster: the test apps
      scale-up-test/           scale-up-test at 3 replicas

  classes/                 the catalog of ClusterClasses, always fully applied:
    docker-kubeadm/          one folder per version, immutable, each holding its
      v1.0/ v1.1/ v1.2/      class and templates and saying what it changed
      common-patch.yaml      what every version shares

  components/karpenter-image/  which Karpenter build runs: one images entry,
                             rewritten by `make karpenter-release`

  components/revisions/    the node upgrade steps, one component each, in order:
    01-v1.34.8-v1.0/         <step>-<Kubernetes version>-<ClusterClass version>;
    02-v1.34.8-v1.1/         each sets the Cluster's class and version
    03-v1.34.11-v1.1/
    04-v1.35.8-v1.1/
    05-v1.35.8-v1.2/

  base/                    what the overlays are built from
    clusters/
      management/            cert-manager, CAPI operator, providers, and the
      karpenter-docker/      the Cluster (class and version left to a revision),
        addons/              Karpenter's RBAC, and its add-ons
    workloads/
      scale-up-test/         the test app, at 0 replicas (the overlay sets the count)

issues/<N>/              one per issue: replicate.sh (make replicate-issue-<N>),
                         README.md
  runs/                  evidence per run (gitignored)

hack/tools/, kubeconfig/ generated: pinned tools, cluster credentials (gitignored)
```

## Deploying

Everything deployed is a folder under `kubernetes/overlays/dev`, built with
one `kustomize build`:

| Overlay | Goes to | Command |
|---|---|---|
| `clusters/management` | the management cluster | `make deploy REVISION=<NN-…>` |
| `clusters/karpenter-docker` | inside the workload cluster | `make workload` (once; unchanged between revisions) |
| `workloads` | inside the workload cluster | `make workloads` / `make workloads-down` |

### Moving between revisions

`clusters/management` lists exactly one revision component. `make deploy
REVISION=03-v1.34.11-v1.1` rewrites that entry with yq, so the file reads:

```yaml
components:
  - ../../../../components/revisions/03-v1.34.11-v1.1
```

and then applies the overlay, re-applying until a fresh cluster's CRDs and
webhooks accept everything. By hand, the same is:

```
make set-revision REVISION=03-v1.34.11-v1.1
kustomize build --enable-helm kubernetes/overlays/dev/clusters/management \
  | kubectl --kubeconfig kubeconfig/capi-karpenter-test.kubeconfig apply --server-side --field-manager=test-bed -f -
```

The overlay file always names the revision last deployed from it, so `git
diff` shows an upgrade before it is applied. `make upgrade TO=<NN-…>` is the
guarded version: only the step after the current one, waiting for the control
plane. `--enable-helm` is required (cert-manager and the operator are Helm
charts), so `kubectl apply -k` does not work.

### The test apps

```
kustomize build kubernetes/overlays/dev/workloads \
  | kubectl --kubeconfig kubeconfig/karpenter-docker.kubeconfig apply --server-side --field-manager=test-bed -f -
```

The replica count is in `workloads/scale-up-test`; `make workloads
SCALE_UP_REPLICAS=<n>` overrides it for one run, and `make workloads-down`
applies it at zero.

## Common tasks

| Task | Command |
|---|---|
| Build everything | `make clusters` |
| Make Karpenter provision workers | `make workloads` (then `make workloads-down`) |
| Watch Machines, Nodes and NodeClaims | `make watch` |
| List the available revisions | `make list-revisions` |
| See the revisions and where the cluster is | `make upgrade-status` |
| Move to the next revision | `make upgrade TO=<NN-…>` |
| Roll only the workers | `make rollout-restart` |
| Deploy Karpenter built from the current commit | `make karpenter-release` |
| Check Karpenter runs that build | `make karpenter-check` |
| List the issues with a reproduction | `make list-issues` |
| Reproduce an issue | `make replicate-issue-<N>` (see `issues/<N>/README.md`) |
| Print what gets deployed | `make render` (and `render-addons`, `render-workloads`) |
| Tear it all down | `make down` |

## Which Karpenter runs

`make karpenter-release` builds the provider checkout this test bed sits in,
tagged with its commit (`<sha>`, or `<sha>-dirty-<hash>` with uncommitted
changes outside this folder), imports it into the workload control plane node,
points `kubernetes/components/karpenter-image` at it with
`kustomize edit set image`, and applies the add-ons. The new tag changes the
Deployment, so Kubernetes replaces the pod; releasing an unchanged commit
changes nothing. The chart is copied from the same checkout, so chart and image
always match.

To test another version of the provider, check it out (switch branch, or
cherry-pick a fix) and release it again. `git diff` on the component shows
which build the test bed last deployed, and `make karpenter-check` whether the
running pod is that build. Set `KARPENTER_TAG` to name a build yourself, for
example to keep a before and an after build apart.

## Adding an issue

Create `issues/<N>/`, named after the issue number, with an executable
`replicate.sh` and a `README.md`; `make replicate-issue-<N>` then runs it, and
`make list-issues` lists it. Before the script starts, the target builds the
clusters if they are not up and runs `make karpenter-release`, so a run always
tests the current commit. Keep the script's evidence in `issues/<N>/runs/`, which is
gitignored.

Branches follow the same convention: a branch carrying only this test bed on
top of upstream main (this one, `test/issue-test-bed`) is the baseline; to
test a fix, branch `test/<issue>` from it, add the issue's reproduction, and
cherry-pick the fix commits.
