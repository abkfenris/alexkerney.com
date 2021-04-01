<!--
.. title: Debugging Kubernetes
.. slug: kubernetes-troubleshooting
.. date: 2016-10-01 13:38:12 UTC
.. tags:
.. category:
.. link:
.. description:
.. type: text
.. nocomments: True
-->

Had my first big hiccup running [Kubernetes](http://kubernetes.io) on [Google Container Engine(GKE)](https://cloud.google.com/container-engine/) yesterday.

<!-- TEASER_END -->

I have been using [Deployments](http://kubernetes.io/docs/user-guide/deployments/) specifying a single replica as a sudo [PetSet](http://kubernetes.io/docs/user-guide/petset/) for a few databases as PetSets are still in alpha.

PetSets are Kubernete's solution to services, where you care about state during cluster changes. While PetSets have now gone alpha in 1.4.0, hosts like GKE can chose not to support alpha features.

Still I have been keeping Kubernetes up to date as soon a possible, as GKE's upgrades are largely painless. This time around I got caught by a race condition when the nodes upgraded.

The first sign of a issue was when I checked that everything was back happy after the nodes upgraded.

```bash
> kubectl get pods | grep -v 'Running' # -v for invert results
NAME                        READY  STATUS             RESTARTS  AGE
sentry-postgres-1257884...  0/1    ContainerCreating  0         16m
underground-postgres-16...  0/1    ContainerCreating  0         16m
```

Uh oh.

What does the deployment thing about things?

```bash
kubectl get deployment underground-postgres
NAME                  DESIRED  CURRENT  UP-TO-DATE  AVAILABLE  AGE
underground-postgres  1        1        1           0          120d
```

At least the deployment knows that something is wrong too, but it doesn't seem to be taking care of the issue as usual.

Lets see whats up with one of those pods.

```bash
> kubectl describe pod sentry-postgres-1257884276-5u5tk
Name:		sentry-postgres-1257884276-5u5tk
Namespace:	default
Node:		gke-k8s-node
Start Time:	Fri, 30 Sep 2016 17:39:58 -0400
#...trimmed here and there...#
Conditions:
  Type		Status
  Initialized 	True
  Ready 	False
  PodScheduled 	True
Volumes:
  sentry-postgres-persistent-storage:
    Type:	GCEPersistentDisk (a Persistent Disk resource in Google Compute Engine)
    PDName:	sentry-postgres-disk
    FSType:	ext4
    Partition:	0
    ReadOnly:	false

Events:

Seen Type     Reason            Message
---- -------  ------            -------------
21m  Warning  FailedScheduling	no nodes available to schedule pods
21m  Warning  FailedScheduling	pod (sentry-postgres-1257884276-5u5tk) failed to fit in any node fit failure on node (gke-k8s-node): PodToleratesNodeTaints

20m  Normal   Scheduled         Successfully assigned sentry-postgres-1257884276-5u5tk to gke-k8s-node

19m  Warning  FailedMount       Failed to attach volume "sentry-postgres-persistent-storage" on node "gke-k8s-default-pool" with: googleapi: Error 404: The resource 'projects/alex-kerney/...details../instances/gke-k8s-node' was not found

19m  Warning  FailedMount       Failed to attach volume "sentry-postgres-persistent-storage" on node "gke-k8s-node" with: error getting instance "gke-k8s-node"

13m  Warning  FailedMount       Unable to mount volumes for pod "sentry-postgres-1257884276-5u5tk_default(499364b1-8756-11e6-b0fe-42010af00052)": timeout expired waiting for volumes to attach/mount for pod "sentry-postgres-1257884276-5u5tk"/"default". list of unattached/unmounted volumes=[sentry-postgres-persistent-storage]

13m  Warning  FailedSync        Error syncing pod, skipping: timeout expired waiting for volumes to attach/mount for pod "sentry-postgres-1257884276-5u5tk"/"default". list of unattached/unmounted volumes=[sentry-postgres-persistent-storage]
```

Trimmed and reformatted some for viewing sanity.

The first couple events were while the nodes were being shuffled around during the upgrade process, but then it gets successfully scheduled onto a node `gke-k8s-node`.

The `FailedMount` and `FailedSync` events are the issue here.

As Kubernetes marked nodes to be drained and their pods shut down, the Replication Controller that the Deployment creates tries to schedule a new pod. In current versions, if there is a disk mounted, it it doesn't always get removed from the shut down pod before the new one tries to mount it.

I found a [couple](https://github.com/kubernetes/kubernetes/issues/29903) of [issues](https://github.com/kubernetes/kubernetes/issues/28709) about this. It also looks like a solution is [coming](https://github.com/kubernetes/kubernetes/pull/32807) in 1.4.1, but I have things broken now.

My first attempts to take care of this were to delete the problematic pods.

```bash
> kubectl delete pod sentry-postgres-1257884276-5u5tk
pod "sentry-postgres-1257884276-5u5tk" deleted

> kubectl get pods | grep -v 'Running'
NAME                          READY  STATUS             RESTARTS  AGE
sentry-postgres-125788427...  0/1    Terminating        0         23m
sentry-postgres-125788427...  0/1    Pending            0         3s
underground-postgres-1659...  0/1    ContainerCreating  0         23m
```

Umm, wait a bit...

```bash
> kubectl get pods | grep -v 'Running'
NAME                         READY  STATUS             RESTARTS  AGE
sentry-postgres-12578842...  0/1    ContainerCreating  0         17s
underground-postgres-165...  0/1    ContainerCreating  0         23m
```

Bummer. It the Replication Controller would still try to create a new pod before the old one was gone and the disk released.

Therefore with the problem being too many pods in existance at the same time, there is a command to change the number of pods that a Replication Controller keeps around.

Lets scale all the way down.
```bash
> kubectl scale --replicas=0 deployment/underground-postgres
deployment "underground-postgres" scaled
```

And then back up.

```bash
> kubectl scale --replicas=1 deployment/underground-postgres
deployment "underground-postgres" scaled
```

Then with a check to see what isn't running:

```bash
> kubectl get pods | grep -v 'Running'
NAME                                        READY     STATUS    RESTARTS   AGE
```

Nada! Zip, zero pods not running! Therefore it's running (which other checks confirmed).
Also giving one of the problematic pods a kick, took care of the other ones.
I shuffling one mount caused the other ones to get checked.

Kubernetes has been awesome to work with.

Each small project can in their own self contained pod ecosystem, and Kubernetes can pack them on as few hosts as possible for the memory requirements.
Most of the time this means that I just have a single host running, but if things get busy, both the worker pods can scale, and the hosts will scale. That way, even if several back episodes from [Underground Garage](http://underground.alexkerney.com) get requested and have to be assembled at the same time, then everything can keep running smoothly. Once the work is done, everything gets scaled back down.

My next step with Kubernetes is to get a [Let's Encrypt](https://letsencrypt.org) setup deployed. [kube-cert-manager](https://github.com/PalmStoneGames/kube-cert-manager) is the most promising looking option right now.

After that comes the big one. Migrating [Riverflo.ws](http://riverflo.ws) to run on Kubernetes.