# Odoo 18 platform on EKS

Odoo 18 with PostgreSQL, MinIO, Keycloak, Prometheus and Grafana. Deployed
to an existing EKS cluster by an existing Jenkins.

```
                 ┌──────────── AWS ALB (AWS Load Balancer Controller) ────────────┐
                 │  odoo.example.com      auth.example.com      grafana.example.com │
                 └──────┬───────────────────────┬──────────────────────┬────────────┘
   namespace odoo-<env> │                       │                      │  namespace monitoring
        ┌───────────────▼──────┐   OIDC  ┌──────▼──────┐        ┌──────▼──────────────────┐
        │ Odoo 18 (Deployment) │ ──────▶ │  Keycloak   │ ◀───── │ Grafana (OIDC login)    │
        │ :8069 http :8072 ws  │         │  realm odoo │        │ Prometheus/Alertmanager │
        └───┬─────────────┬────┘         └──────┬──────┘        │ blackbox exporter       │
            │ attachments │ SQL                 │ SQL           └──────────┬──────────────┘
        ┌───▼────┐   ┌────▼─────────────────────▼──┐                       │ scrapes
        │ MinIO  │   │ PostgreSQL 16 (+exporter)   │ ◀─────────────────────┘ ServiceMonitors,
        └────────┘   │ dbs: odoo, keycloak         │                         Probes, alerts
                     └─────────────────────────────┘
```

| Component | How it runs | Notes |
|---|---|---|
| Odoo 18 | Deployment built from `docker/odoo` | Adds OCA `auth_oidc` (Keycloak login) and `fs_attachment_s3` (files in MinIO). The pods keep no state. |
| PostgreSQL 16 | StatefulSet on an EBS gp3 volume | Holds two databases (`odoo`, `keycloak`). Includes `postgres-exporter` and a nightly `pg_dump` to MinIO. |
| MinIO | StatefulSet on an EBS gp3 volume | Built from source (`docker/minio`) and pushed to your ECR, because upstream no longer publishes images. |
| Keycloak 26 | Deployment | Realm `odoo` with the `odoo` and `grafana` clients, imported on first start. |
| Prometheus, Alertmanager, Grafana | `kube-prometheus-stack` Helm chart | One install for the whole cluster. Includes the Odoo Platform dashboard and alerts. |
| Blackbox exporter | Helm chart | Health probes for Odoo and Keycloak. Odoo has no `/metrics` endpoint. |

## Repository layout

```
Jenkinsfile                      pipeline: build -> push to ECR -> monitoring -> deploy -> smoke test
docker/odoo/                     Odoo image (OCA modules + init/config/backup scripts)
docker/minio/                    MinIO built from source
addons/                          your custom Odoo modules
helm/odoo-platform/              chart for Postgres, MinIO, Keycloak, Odoo, monitoring resources
environments/{dev,prod}/         per-environment values (domains, sizes, certificate)
monitoring/                      kube-prometheus-stack + blackbox exporter values
k8s/cluster/                     cluster-level objects (gp3 StorageClass)
scripts/                         secrets, monitoring install, deploy, smoke test
```

## Prerequisites

### EKS cluster
- **AWS Load Balancer Controller** installed (IngressClass `alb`).
- **Amazon EBS CSI driver** add-on installed. The pipeline creates the `gp3` StorageClass.
- An **ACM certificate** for your domains.
- **DNS records** (Route 53 or external-dns) for the Odoo, Keycloak, MinIO console and Grafana hosts, pointing at the ALBs.
- Nodes with at least about 6 vCPU and 12 GiB free for dev. The `prod` values need more.

### Jenkins agent
- Tools: `docker`, `aws` CLI v2, `kubectl`, `helm` 3, `jq`, `git`.
- Plugins: Pipeline, Timestamper, and *CloudBees AWS Credentials* (only if you use `AWS_CREDENTIALS_ID`).
- AWS identity (agent IAM role or a Jenkins AWS credential) with:
  - ECR: create repositories, push images, describe images.
  - `eks:DescribeCluster`, plus Kubernetes admin rights in the cluster (an EKS access entry with `AmazonEKSClusterAdminPolicy`, or an `aws-auth` mapping).

## First-time setup

1. Edit `environments/dev/values.yaml` and `environments/prod/values.yaml`:
   - set the domains and `alb.ingress.kubernetes.io/certificate-arn`
   - set `keycloak.grafanaUrl`
2. Edit `monitoring/kube-prometheus-stack-values.yaml`:
   - Grafana host, certificate, and the Keycloak URLs in `auth.generic_oauth`. These point at the prod Keycloak by default.
   - Alertmanager receivers (Slack, email, etc.).
3. Create a Jenkins **Pipeline** job:
   - Definition: *Pipeline script from SCM*
   - Repository: this repo
   - Script path: `Jenkinsfile`
4. Run it once with the default parameters. Jenkins only shows the parameter form from the second run on. Then run it with:
   - `ENVIRONMENT=dev`
   - `AWS_REGION`, `EKS_CLUSTER_NAME`
   - `AWS_CREDENTIALS_ID` (or leave it empty to use the agent's IAM role)

## What the pipeline does

| Stage | What happens |
|---|---|
| Validate | Runs `helm lint` and `helm template` with the environment's values. |
| Build & push images | Creates the ECR repositories if missing. Builds the Odoo image, tagged `<git-sha>-<build>`. Builds MinIO only when its release isn't in ECR yet. |
| Connect to EKS | Runs `aws eks update-kubeconfig` into the workspace. |
| Approve production | Waits for a manual `input` step, for `prod` only. |
| Cluster prerequisites | Creates the gp3 StorageClass. Warns if the ALB controller or the EBS CSI driver is missing. |
| Secrets | Runs `scripts/create-secrets.sh`, which creates the `odoo-platform-secrets` Secret (see below). |
| Monitoring stack | Runs `scripts/install-monitoring.sh`, which installs `kube-prometheus-stack` and the blackbox exporter. |
| Deploy platform | Runs `helm upgrade --install` of `helm/odoo-platform`. The `odoo-init` Job runs before every upgrade (details below). |
| Smoke test | From inside an Odoo pod, checks the Odoo health endpoint and login page, the Keycloak OIDC discovery URL, and MinIO health. |

**The `odoo-init` Job** (`docker/odoo/scripts/init-db.sh`):
- On the first deploy, it creates the database and installs `odoo.init.installModules`.
- Later, it installs any modules that are missing and runs `-u` for the `ODOO_UPDATE_MODULES` parameter.
- Every run, it configures the Keycloak provider, MinIO storage and `web.base.url`.
- It is idempotent.

`ACTION=destroy` uninstalls the release. The PVCs (data) and the Secret are kept.

## Secrets

`scripts/create-secrets.sh` manages the Secret `odoo-platform-secrets` in each namespace. For each key it uses, in order:
1. an environment variable with that name, if set (for example from a Jenkins credential);
2. otherwise, the value already in the cluster;
3. otherwise, a newly generated random value.

Values are never rotated by accident. Read one with:

```bash
kubectl -n odoo-dev get secret odoo-platform-secrets -o jsonpath='{.data.odoo-admin-password}' | base64 -d
```

| Key | Used for |
|---|---|
| `odoo-admin-password` | Odoo `admin` user (set at first init), and the database manager master password |
| `keycloak-admin-password` | Keycloak bootstrap admin (`admin`, master realm) |
| `postgres-password`, `odoo-db-password`, `keycloak-db-password` | Database roles |
| `minio-root-user`, `minio-root-password` | MinIO, also used by Odoo for S3 access |
| `odoo-oidc-client-secret`, `grafana-oidc-client-secret` | Keycloak client secrets |

The Grafana admin password is in `monitoring/grafana-admin`.

For production, consider AWS Secrets Manager with the External Secrets Operator instead.

## Logging in

- **Odoo**: open `https://odoo.<domain>` and either:
  - click **Log in with Keycloak**, or
  - log in as `admin` with `odoo-admin-password`.

  By default (`odoo.oidc.signupScope: b2b`), only users you invite from Odoo can log in through Keycloak. Set `b2c` to let any realm user get a portal account.
- **Keycloak admin**: `https://auth.<domain>/admin`, user `admin`. Create users in the `odoo` realm.
- **Grafana**: `https://grafana.<domain>`. Log in through Keycloak. Realm roles `grafana-admin` and `grafana-editor` map to Grafana Admin and Editor; everyone else is a Viewer. The *Odoo Platform* dashboard is in the *Odoo Platform* folder.
- **MinIO console**: `https://minio.<domain>` (dev only). In prod, use `kubectl -n odoo-prod port-forward svc/minio 9001`.

## Monitoring

Alerts (`templates/monitoring/prometheusrule.yaml`):

| Alert | Fires when |
|---|---|
| OdooDown | Odoo's health check fails |
| OdooSlow | Odoo's health check is slow |
| OdooReplicasUnavailable | Fewer Odoo pods are available than requested |
| KeycloakDown | Keycloak is not ready |
| PostgresDown | PostgreSQL is unreachable |
| PostgresConnectionsHigh | More than 80% of `max_connections` are in use |
| MinioDown | MinIO is down |
| VolumeAlmostFull | A volume is more than 85% full |
| OdooInitJobFailed | The `odoo-init` Job failed |
| DatabaseBackupMissing | No successful backup in 36 hours |

The *Odoo Platform* Grafana dashboard shows:
- up/down status for each component
- response time
- CPU and memory per component
- PostgreSQL connections and database size
- MinIO bucket size
- Keycloak logins
- volume usage

Community dashboards for PostgreSQL (9628) and MinIO (13502) are added too.

## Day-2 operations

- **Custom modules**: add them under `addons/` and to `odoo.init.installModules`. Run the pipeline. To upgrade modules later, put them in `ODOO_UPDATE_MODULES` (or `all`).
- **Scaling Odoo**: `odoo.replicas`, or `odoo.autoscaling` (on in prod). Files are in MinIO, so pods share no disk. Login sessions stay on one pod through ALB sticky sessions. To keep sessions across restarts, set `odoo.persistence` with an EFS (ReadWriteMany) StorageClass.
- **Backups**: the `postgres-backup` CronJob writes to `s3://odoo-backups/postgres/<db>/` in MinIO. Restore with:

  ```bash
  pg_restore -d <db> --clean <file>
  ```

  The MinIO volume itself is not backed up. Take EBS snapshots, or replicate the bucket to S3.
- **Managed services**: for prod, consider Amazon RDS for PostgreSQL:
  - set `postgres.enabled=false` and `externalDatabase.host`
  - create the `odoo` role (with CREATEDB) and the `keycloak` role and database yourself

  For Amazon S3, set `minio.enabled=false` and `odoo.s3.endpoint`, and put the access keys in `minio-root-user` and `minio-root-password`.
- **Keycloak realm changes**: the realm is imported only when it doesn't exist yet. Make later changes in the Keycloak admin console.
- **Version pins**:
  - OCA module commits: `docker/odoo/Dockerfile`
  - MinIO release: `MINIO_RELEASE` in `Jenkinsfile`
  - Helm chart versions: `KPS_CHART_VERSION` and `BLACKBOX_CHART_VERSION` in `Jenkinsfile`
  - Image tags: `helm/odoo-platform/values.yaml`

## Running without Jenkins

```bash
aws eks update-kubeconfig --name <cluster> --region <region>
kubectl apply -f k8s/cluster/storageclass-gp3.yaml
scripts/create-secrets.sh odoo-dev
GRAFANA_SSO_NAMESPACE=odoo-dev scripts/install-monitoring.sh
MINIO_IMAGE=<account>.dkr.ecr.<region>.amazonaws.com/odoo-platform/minio:RELEASE.2025-10-15T17-29-55Z \
  scripts/deploy-app.sh dev <account>.dkr.ecr.<region>.amazonaws.com/odoo-platform/odoo <tag>
scripts/smoke-test.sh odoo-dev
```
