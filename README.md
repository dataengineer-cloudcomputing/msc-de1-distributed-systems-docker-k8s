# MSc DE1 — Distributed Systems: Docker & Local Kubernetes Project

## 1. Project objective and architecture overview

This project takes an existing, non-containerized Flask REST API and builds a
complete, secure, reproducible containerization and orchestration workflow
around it:

```
Flask app (unmodified core logic)
-> Dockerfile (multi-stage, non-root, hardened)
-> Docker Compose (local verification, hardened runtime options)
-> Docker Hub (public image, versioned + latest tags)
-> kind cluster (1 control-plane + 2 worker nodes)
-> Kubernetes manifests (namespace, deployment, service, networkpolicy,
configmap) with security hardening, probes, resource limits
```


The app itself was not redesigned: only a production WSGI server (Gunicorn)
replaces the Flask development server, and one new route (`/version`) was
added later to demonstrate a rolling update.

## 2. Original starter application

https://github.com/ubc/flask-sample-app

Forked and renamed to this repository:
https://github.com/dataengineer-cloudcomputing/msc-de1-distributed-systems-docker-k8s

## 3. Prerequisites

- Docker Desktop (includes Docker Engine, Compose, and Docker Scout)
- Python 3.12+ and `pip`
- [`kind`](https://kind.sigs.k8s.io/) and `kubectl` (installed via Homebrew:
  `brew install kind kubectl`)
- A Docker Hub account (for pulling/pushing the published image)
- macOS note: the built-in **AirPlay Receiver** service listens on port 5000
  by default, which conflicts with this app's default port. All examples
  below map the container's port 5000 to **host port 8080** to avoid this.
  Alternatively, disable AirPlay Receiver in System Settings > General >
  AirDrop & Handoff.

## 4. Running the original application locally (baseline)

```bash
python -m venv venv
source venv/bin/activate
pip install -r requirements.txt
python run.py
```

The app listens on `http://127.0.0.1:5000`. In another terminal:

```bash
curl -4 http://localhost:5000/
curl -4 http://localhost:5000/items
curl -4 http://localhost:5000/items/1
curl -4 http://localhost:5000/items -H "Content-Type: application/json" -d '{"name":"test"}'
```

Run the unit tests:

```bash
python -m unittest discover tests
```

Baseline evidence (command output) is saved in `evidence/baseline.txt`.

## 5. Building and running the Docker image

```bash
docker build --provenance=false --sbom=false -t flask-sample-app:1.0.0 .
docker run -d --name flask-app -p 8080:5000 flask-sample-app:1.0.0
curl -4 http://localhost:8080/
docker logs flask-app
docker stop flask-app && docker rm flask-app
```

The image uses a multi-stage build: dependencies are installed in a `builder`
stage venv, and only that venv plus the application code are copied into the
final `python:3.14-slim` runtime stage. The container runs as a dedicated
non-root user (`appuser`, uid/gid 999), exposes only port 5000, and includes
a Docker-level `HEALTHCHECK` implemented in pure Python (no extra `curl`
dependency).

## 6. Running with Docker Compose

```bash
docker compose up -d --build
docker compose ps
curl -4 http://localhost:8080/
docker compose logs
docker compose down
```

`compose.yaml` adds runtime hardening on top of the image: `read_only: true`
root filesystem (with a `tmpfs` mount on `/tmp`), `cap_drop: [ALL]`, and
`no-new-privileges:true`.

## 7. Docker Hub

Public image: https://hub.docker.com/r/whale92400/msc-de1-flask-app

Tags published: `1.0.0`, `1.1.0` (versioned), `latest`

Image used for the final Kubernetes deployment (after rollback): `whale92400/msc-de1-flask-app:1.0.0`

## 8. Creating the local Kubernetes cluster (kind)

```bash
kind create cluster --config kind/kind-config.yaml
kubectl cluster-info --context kind-msc-de1-cluster
kubectl get nodes -o wide
```

This creates `msc-de1-cluster` with 1 control-plane node and 2 worker nodes
(see `kind/kind-config.yaml`).

## 9. Deploying the Kubernetes manifests

```bash
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/
kubectl get all -n msc-de1-project
```

Manifests in `k8s/`:
- `namespace.yaml` — dedicated `msc-de1-project` namespace
- `deployment.yaml` — 2 replicas, rolling update strategy, readiness/liveness
  probes, CPU/memory requests & limits, hardened pod/container security
  context
- `service.yaml` — ClusterIP service exposing port 80 -> 5000
- `network-policy.yaml` — restricts ingress to port 5000
- `optional-config-or-secret.yaml` — ConfigMap for non-sensitive env config

## 10. Accessing and testing the application

```bash
kubectl port-forward -n msc-de1-project svc/flask-app-service 8081:80
```

In another terminal:

```bash
curl -4 http://localhost:8081/
curl -4 http://localhost:8081/items
```

Distributed-systems behavior demonstrations (self-healing, scaling, rolling
update and rollback) are documented with command output in
`evidence/k8s/`.

## 11. Deleting / cleaning up the local cluster

```bash
kind delete cluster --name msc-de1-cluster
```

To also remove local Docker resources:

```bash
docker compose down
docker rmi flask-sample-app:1.0.0 flask-sample-app:1.1.0
```

## 12. Security decisions and known limitations

- **Non-root everywhere**: the image runs as `appuser` (uid/gid 999) in
  Docker, Compose, and Kubernetes (`runAsNonRoot`, `runAsUser: 999`).
- **Removed build-time tooling from the runtime image**: `pip`, `setuptools`,
  `pkg_resources` and pip's vendored `msgpack` copy are deleted from both the
  venv and the base image's system Python after dependency installation,
  since Gunicorn never invokes `pip` at runtime. This resolved 4 of the
  vulnerabilities found by the initial Docker Scout scan (57 -> 53
  vulnerabilities). See `security/vulnerability-scan.txt`.
- **Remaining findings**: all 53 remaining vulnerabilities come from Debian
  system packages bundled in the official `python:3.14-slim` base image
  (perl, glibc, systemd, tar, etc.) that are never invoked by the
  application at runtime. Upgrading or patching them individually would mean
  patching the base OS image itself, which is out of scope for an
  application-level Dockerfile; the risk is accepted and documented rather
  than ignored.
- **Read-only root filesystem**: enabled in both Compose and Kubernetes
  (`read_only: true` / `readOnlyRootFilesystem: true`), with a writable
  `tmpfs`/`emptyDir` mounted only at `/tmp`. This works because the app
  keeps its data in memory and `PYTHONDONTWRITEBYTECODE=1` prevents `.pyc`
  writes.
- **Capabilities and privilege escalation**: `cap_drop: [ALL]` and
  `allowPrivilegeEscalation: false` everywhere; the app does not need any
  Linux capability (it binds to an unprivileged port).
- **NetworkPolicy limitation**: `k8s/network-policy.yaml` restricts ingress
  to port 5000, but kind's default CNI (kindnet) does not enforce
  NetworkPolicy resources out of the box. The policy documents the intended
  network isolation; enforcing it would require installing a
  policy-capable CNI such as Calico or Cilium, which was not done here to
  keep the cluster setup simple for local grading.
- **macOS AirPlay Receiver port conflict**: documented in the Prerequisites
  section; host port 8080 is used instead of 5000 throughout.