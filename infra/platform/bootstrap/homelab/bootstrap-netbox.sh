#!/usr/bin/env bash
set -euo pipefail

# Deploy NetBox to the existing private Homelab K3s node, create a local-only
# bootstrap credential file, and seed the evidence-backed inventory.
#
# This is an intentionally direct bootstrap. The Argo Application manifest is
# prepared for the next GitHub-backed sync after these changes are committed;
# do not put generated credentials or Kubernetes Secrets in Git.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
MANIFEST_DIR="$ROOT/infra/platform/gitops/homelab/netbox"
SEED_FILE="$ROOT/infra/platform/bootstrap/homelab/netbox-seed.py"
K3S_HOST="${K3S_HOST:-192.168.152.114}"
K3S_USER="${K3S_USER:-soloadmin}"
NAMESPACE="${NETBOX_NAMESPACE:-apps-netbox-homelab}"
NETBOX_HOSTNAME="${NETBOX_HOSTNAME:-netbox.homelab.local}"
NETBOX_IMAGE="${NETBOX_IMAGE:-docker.io/netboxcommunity/netbox:v4.6.7-5.0.2}"
CREDENTIALS_FILE="${NETBOX_CREDENTIALS_FILE:-/home/bookchaowalit/.config/solo-empire/netbox/credentials.env}"
REMOTE="${K3S_USER}@${K3S_HOST}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)

if [[ ! -d "$MANIFEST_DIR" || ! -f "$SEED_FILE" ]]; then
  echo "NetBox bootstrap assets are missing" >&2
  exit 1
fi

mkdir -p "$(dirname "$CREDENTIALS_FILE")"
if [[ ! -f "$CREDENTIALS_FILE" ]]; then
  umask 077
  {
    printf '%s\n' "NETBOX_ADMIN_USERNAME=admin"
    printf '%s\n' "NETBOX_ADMIN_EMAIL=admin@homelab.local"
    printf '%s\n' "NETBOX_ADMIN_PASSWORD=$(openssl rand -hex 24)"
    printf '%s\n' "NETBOX_DB_PASSWORD=$(openssl rand -hex 24)"
    printf '%s\n' "NETBOX_REDIS_PASSWORD=$(openssl rand -hex 24)"
    printf '%s\n' "NETBOX_REDIS_CACHE_PASSWORD=$(openssl rand -hex 24)"
    printf '%s\n' "NETBOX_SECRET_KEY=$(openssl rand -hex 48)"
    printf '%s\n' "NETBOX_API_TOKEN_PEPPER_1=$(openssl rand -hex 32)"
  } > "$CREDENTIALS_FILE"
  chmod 600 "$CREDENTIALS_FILE"
fi

set -a
# shellcheck disable=SC1090
. "$CREDENTIALS_FILE"
set +a

required=(
  NETBOX_ADMIN_USERNAME
  NETBOX_ADMIN_EMAIL
  NETBOX_ADMIN_PASSWORD
  NETBOX_DB_PASSWORD
  NETBOX_REDIS_PASSWORD
  NETBOX_REDIS_CACHE_PASSWORD
  NETBOX_SECRET_KEY
  NETBOX_API_TOKEN_PEPPER_1
)
for key in "${required[@]}"; do
  if [[ -z "${!key:-}" ]]; then
    echo "Missing $key in $CREDENTIALS_FILE" >&2
    exit 1
  fi
done

remote_kubectl() {
  ssh "${SSH_OPTS[@]}" "$REMOTE" kubectl "$@"
}

apply_manifest() {
  local manifest="$1"
  remote_kubectl apply -f - < "$manifest"
}

echo "Checking K3s access on $K3S_HOST"
remote_kubectl get node solo-k3s-server-01 >/dev/null

echo "Applying NetBox namespace"
apply_manifest "$MANIFEST_DIR/namespace.yaml"

runtime_env="$(mktemp)"
admin_env="$(mktemp)"
cleanup_local() {
  rm -f "$runtime_env" "$admin_env"
}
trap cleanup_local EXIT
chmod 600 "$runtime_env" "$admin_env"
{
  printf '%s\n' "DB_PASSWORD=$NETBOX_DB_PASSWORD"
  printf '%s\n' "REDIS_PASSWORD=$NETBOX_REDIS_PASSWORD"
  printf '%s\n' "REDIS_CACHE_PASSWORD=$NETBOX_REDIS_CACHE_PASSWORD"
  printf '%s\n' "SECRET_KEY=$NETBOX_SECRET_KEY"
  printf '%s\n' "API_TOKEN_PEPPER_1=$NETBOX_API_TOKEN_PEPPER_1"
} > "$runtime_env"
{
  printf '%s\n' "SUPERUSER_NAME=$NETBOX_ADMIN_USERNAME"
  printf '%s\n' "SUPERUSER_EMAIL=$NETBOX_ADMIN_EMAIL"
  printf '%s\n' "SUPERUSER_PASSWORD=$NETBOX_ADMIN_PASSWORD"
} > "$admin_env"

runtime_remote="/tmp/netbox-runtime-env.$$"
scp "${SSH_OPTS[@]}" "$runtime_env" "$REMOTE:$runtime_remote" >/dev/null
ssh "${SSH_OPTS[@]}" "$REMOTE" "set -eu; kubectl -n '$NAMESPACE' create secret generic netbox-runtime --from-env-file='$runtime_remote' --dry-run=client -o yaml | kubectl apply -f -; rm -f '$runtime_remote'"

echo "Applying NetBox workloads"
for manifest in \
  "$MANIFEST_DIR/postgres.yaml" \
  "$MANIFEST_DIR/valkey.yaml" \
  "$MANIFEST_DIR/netbox.yaml" \
  "$MANIFEST_DIR/networkpolicy.yaml"; do
  apply_manifest "$manifest"
done

echo "Waiting for NetBox dependencies and web"
remote_kubectl -n "$NAMESPACE" rollout status statefulset/netbox-postgres --timeout=240s
remote_kubectl -n "$NAMESPACE" rollout status deployment/netbox-redis --timeout=180s
remote_kubectl -n "$NAMESPACE" rollout status deployment/netbox-redis-cache --timeout=180s
remote_kubectl -n "$NAMESPACE" rollout status deployment/netbox --timeout=900s
remote_kubectl -n "$NAMESPACE" rollout status deployment/netbox-worker --timeout=240s

admin_remote="/tmp/netbox-admin-env.$$"
scp "${SSH_OPTS[@]}" "$admin_env" "$REMOTE:$admin_remote" >/dev/null
ssh "${SSH_OPTS[@]}" "$REMOTE" "set -eu; kubectl -n '$NAMESPACE' create secret generic netbox-bootstrap --from-env-file='$admin_remote' --dry-run=client -o yaml | kubectl apply -f -; rm -f '$admin_remote'"

echo "Creating or updating the local NetBox admin account"
remote_kubectl -n "$NAMESPACE" delete job/netbox-admin-bootstrap --ignore-not-found >/dev/null
cat <<EOF | ssh "${SSH_OPTS[@]}" "$REMOTE" kubectl apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: netbox-admin-bootstrap
  namespace: $NAMESPACE
  labels:
    app.kubernetes.io/name: netbox-admin-bootstrap
    app.kubernetes.io/part-of: solo-empire
    solo.empire/team: platform
    solo.empire/environment: homelab
    app.kubernetes.io/component: bootstrap
spec:
  backoffLimit: 2
  ttlSecondsAfterFinished: 300
  template:
    metadata:
      labels:
        app.kubernetes.io/name: netbox-admin-bootstrap
        app.kubernetes.io/part-of: solo-empire
        solo.empire/team: platform
        solo.empire/environment: homelab
        app.kubernetes.io/component: bootstrap
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext:
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: bootstrap
          image: $NETBOX_IMAGE
          imagePullPolicy: IfNotPresent
          envFrom:
            - secretRef:
                name: netbox-runtime
            - secretRef:
                name: netbox-bootstrap
          env:
            - name: DB_HOST
              value: netbox-postgres
            - name: DB_NAME
              value: netbox
            - name: DB_USER
              value: netbox
            - name: REDIS_HOST
              value: netbox-redis
            - name: REDIS_DATABASE
              value: "0"
            - name: REDIS_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: netbox-runtime
                  key: REDIS_PASSWORD
            - name: REDIS_CACHE_HOST
              value: netbox-redis-cache
            - name: REDIS_CACHE_DATABASE
              value: "1"
            - name: REDIS_CACHE_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: netbox-runtime
                  key: REDIS_CACHE_PASSWORD
            - name: ALLOWED_HOSTS
              value: $NETBOX_HOSTNAME localhost
            - name: SECRET_KEY
              valueFrom:
                secretKeyRef:
                  name: netbox-runtime
                  key: SECRET_KEY
            - name: API_TOKEN_PEPPER_1
              valueFrom:
                secretKeyRef:
                  name: netbox-runtime
                  key: API_TOKEN_PEPPER_1
          command:
            - /bin/sh
            - -c
          args:
            - >-
              /opt/netbox/venv/bin/python /opt/netbox/netbox/manage.py shell -c
              "import os; from django.contrib.auth import get_user_model; User=get_user_model(); user,created=User.objects.get_or_create(username=os.environ['SUPERUSER_NAME'], defaults={'email': os.environ['SUPERUSER_EMAIL']}); user.email=os.environ['SUPERUSER_EMAIL']; user.is_active=True; user.is_staff=True; user.is_superuser=True; user.set_password(os.environ['SUPERUSER_PASSWORD']); user.save(); print('NetBox admin bootstrap ' + ('created' if created else 'updated'))"
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: false
            capabilities:
              drop:
                - ALL
          resources:
            requests:
              cpu: 25m
              memory: 128Mi
            limits:
              cpu: 200m
              memory: 256Mi
EOF
remote_kubectl -n "$NAMESPACE" wait --for=condition=complete job/netbox-admin-bootstrap --timeout=180s
remote_kubectl -n "$NAMESPACE" delete secret netbox-bootstrap --ignore-not-found >/dev/null

echo "Seeding evidence-backed Homelab inventory"
ssh "${SSH_OPTS[@]}" "$REMOTE" "kubectl -n '$NAMESPACE' exec -i deploy/netbox -- /opt/netbox/venv/bin/python /opt/netbox/netbox/manage.py shell -c 'exec(open(\"/dev/stdin\").read())'" < "$SEED_FILE"

echo "Running private ingress smoke check"
curl -fsS -o /dev/null -H "Host: $NETBOX_HOSTNAME" "http://$K3S_HOST/login/"

echo "NetBox is ready: http://$NETBOX_HOSTNAME/"
echo "Admin username: $NETBOX_ADMIN_USERNAME"
echo "Credential file: $CREDENTIALS_FILE (mode 600; not committed)"
echo "Inventory assets are seeded from operations/platform/HOMELAB-INVENTORY.md"
