#!/usr/bin/env bash
export DOCKERIMAGE=${DOCKERIMAGE:-syncano/platform}
export VERSION="$2"

TARGET="$1"
PUSH=true
MIGRATIONS=false
DEFAULT_CARE_ARGUMENTS=""

usage() { echo "* Usage: $0 <environment> <version> [--skip-gitlog][--skip-push][--migration]" >&2; exit 1; }
[[ -n $TARGET ]] || usage
[[ -n $VERSION ]] || usage

set -euo pipefail

if ! command -v kubectl > /dev/null; then
    echo "! kubectl not installed" >&2; exit 1
fi

if [[ ! -f "deploy/env/${TARGET}.env" ]]; then
    echo "! environment ${TARGET} does not exist in deploy/env/"; exit 1
fi


# Parse last git message (for PR integration).
GITLOG=$(git log -1)
[[ $GITLOG == *"[migration]"* ]] && MIGRATIONS=true

# Parse arguments.
for PARAM in "${@:3}"; do
    case $PARAM in
        --migration)
          MIGRATIONS=true
          ;;
        --skip-push)
          PUSH=false
          ;;
        *)
          usage
          ;;
    esac
done

envsubst() {
    for var in $(compgen -e); do
        echo "$var: \"${!var//\"/\\\"}\""
    done | PYTHONWARNINGS=ignore jinja2 "$1"
}


echo "* Starting deployment for $TARGET at $VERSION for $DOCKERIMAGE."

# Setup environment variables.
set -a
# shellcheck disable=SC1090
source deploy/env/"${TARGET}".env
set +a
BUILDTIME=$(date +%Y-%m-%dT%H%M)
export BUILDTIME


# Push docker image.
if $PUSH; then
    echo "* Tagging $DOCKERIMAGE $VERSION."
    docker tag "$DOCKERIMAGE" "$DOCKERIMAGE":"$VERSION"

    echo "* Pushing $DOCKERIMAGE:$VERSION."
    docker push "$DOCKERIMAGE":"$VERSION"
fi

IMAGE="$DOCKERIMAGE":"$VERSION"
export IMAGE


# Create configmap.
echo "* Updating ConfigMap."
CONFIGMAP="apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: platform\ndata:\n"
while read -r line; do
    if [[ -n "${line}" && "${line}" != "#"* ]]; then
        CONFIGMAP+="  ${line%%=*}: \"${line#*=}\"\n"
    fi
done < deploy/env/"${TARGET}".env
echo -e "$CONFIGMAP" | kubectl apply -f -


# Create secrets.
echo "* Updating Secrets."
SECRETS="apiVersion: v1\nkind: Secret\nmetadata:\n  name: platform\ntype: Opaque\ndata:\n"
while read -r line; do
    if [[ -n "${line}" && "${line}" != "#"* ]]; then
        SECRETS+="  ${line%%=*}: $(echo -n "${line#*=}" | base64 | tr -d '\n')\n"
    fi
done < deploy/env/"${TARGET}".secrets.unenc
echo -e "$SECRETS" | kubectl apply -f -


# Migrate database.
if $MIGRATIONS; then
    echo "* Starting migration job."
    export CARE_ARGUMENTS=${CARE_ARGUMENTS:-$DEFAULT_CARE_ARGUMENTS}
    kubectl delete job/platform-migration 2>/dev/null || true
    envsubst deploy/yaml/migration-job.yml.j2 | kubectl apply -f -
    for _ in {1..300}; do
        echo ". Waiting for migration job."
        sleep 1
        PODNAME=$(kubectl get pods -l job-name=platform-migration -a --sort-by=.status.startTime -o name 2>/dev/null | tail -n1)
        [ -z "$PODNAME" ] && continue

        kubectl attach "$PODNAME" 2> /dev/null || true
        SUCCESS=$(kubectl get jobs platform-migration -o jsonpath='{.status.succeeded}' 2>/dev/null | grep -v 0 || true)
        [ -n "$SUCCESS" ] && break
    done

    if [ -z "$SUCCESS" ]; then
        echo "! Migration failed!"
        exit 1
    fi
    kubectl delete job/platform-migration
fi

# Start with deployment (web + worker).
echo "* Deploying Web."
REPLICAS=$(kubectl get deployment/platform-web -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "${WEB_MIN}")
export REPLICAS
envsubst deploy/yaml/web-deployment.yml.j2 | kubectl apply -f -
envsubst deploy/yaml/web-hpa.yml.j2 | kubectl apply -f -

echo "* Deploying Service for Web."
envsubst deploy/yaml/web-service.yml.j2 | kubectl apply -f -

REPLICAS=$(kubectl get deployment/platform-worker -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "${WORKER_MIN}")
export REPLICAS
echo "* Deploying Worker."
envsubst deploy/yaml/worker-deployment.yml.j2 | kubectl apply -f -
envsubst deploy/yaml/worker-hpa.yml.j2 | kubectl apply -f -

# Deploy legacy Codebox.
if [ "${LEGACY_CODEBOX_ENABLED}" == "true" ]; then
    kubectl create configmap platform-legacy-codebox-dind --from-file=deploy/dind-run.sh -o yaml --dry-run | kubectl apply -f -
    REPLICAS=$(kubectl get deployment/platform-legacy-codebox -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "${LEGACY_CODEBOX_MIN}")
    export REPLICAS
    echo "* Deploying legacy Codebox."
    envsubst deploy/yaml/codebox-daemonset.yml.j2 | kubectl apply -f -
    envsubst deploy/yaml/codebox-deployment.yml.j2 | kubectl apply -f -
    envsubst deploy/yaml/codebox-hpa.yml.j2 | kubectl apply -f -
fi

# Wait for web and worker deployments to finish.
echo
echo ". Waiting for Web deployment to finish..."
kubectl rollout status deployment/platform-web

echo ". Waiting for Worker deployment to finish..."
kubectl rollout status deployment/platform-worker
