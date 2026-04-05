#!/bin/sh

set -eu

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_var() {
  var_name="$1"
  var_value="$(eval "printf '%s' \"\${$var_name:-}\"")"
  [ -n "$var_value" ] || fail "$var_name must be set."
}

require_var DEPLOY_ENV
require_var DEPLOY_REGION
require_var DEPLOY_IMAGE_TAG

deploy_env="$(printf '%s' "$DEPLOY_ENV" | tr '[:upper:]' '[:lower:]')"
deploy_region="$(printf '%s' "$DEPLOY_REGION" | tr '[:upper:]' '[:lower:]')"

chart_dir="k8s/helm/atlas-execution-processor"
default_values_file="$chart_dir/values-$deploy_env-$deploy_region.yaml"
values_file="${DEPLOY_VALUES_FILE:-$default_values_file}"
release_prefix="${HELM_RELEASE_PREFIX:-aep}"
namespace_prefix="${KUBE_NAMESPACE_PREFIX:-aep}"
helm_timeout="${HELM_TIMEOUT:-10m}"
release_name="${HELM_RELEASE_NAME:-$release_prefix-$deploy_env-$deploy_region}"
namespace="${KUBE_NAMESPACE:-$namespace_prefix-$deploy_env-$deploy_region}"

[ -d "$chart_dir" ] || fail "Helm chart directory not found: $chart_dir"
[ -f "$values_file" ] || fail "Values file not found: $values_file"
[ -n "${CI_REGISTRY_IMAGE:-}" ] || fail "CI_REGISTRY_IMAGE must be available."

if [ -n "${KUBE_CONFIG:-}" ] && [ -f "$KUBE_CONFIG" ]; then
  export KUBECONFIG="$KUBE_CONFIG"
elif [ -n "${KUBE_CONFIG_B64:-}" ]; then
  mkdir -p .kube
  printf '%s' "$KUBE_CONFIG_B64" | base64 -d > .kube/config
  export KUBECONFIG="$PWD/.kube/config"
else
  fail "Provide cluster credentials through a file variable named KUBE_CONFIG or a base64 variable named KUBE_CONFIG_B64."
fi

mkdir -p build/helm
rendered_file="build/helm/$release_name-rendered.yaml"

echo "Deploy target"
echo "  env: $deploy_env"
echo "  region: $deploy_region"
echo "  release: $release_name"
echo "  namespace: $namespace"
echo "  values file: $values_file"
echo "  image: $CI_REGISTRY_IMAGE:$DEPLOY_IMAGE_TAG"

helm lint "$chart_dir" \
  -f "$values_file" \
  --set image.repository="$CI_REGISTRY_IMAGE" \
  --set image.tag="$DEPLOY_IMAGE_TAG"

helm template "$release_name" "$chart_dir" \
  --namespace "$namespace" \
  -f "$values_file" \
  --set image.repository="$CI_REGISTRY_IMAGE" \
  --set image.tag="$DEPLOY_IMAGE_TAG" \
  > "$rendered_file"

helm upgrade --install "$release_name" "$chart_dir" \
  --namespace "$namespace" \
  --create-namespace \
  --wait \
  --timeout "$helm_timeout" \
  -f "$values_file" \
  --set image.repository="$CI_REGISTRY_IMAGE" \
  --set image.tag="$DEPLOY_IMAGE_TAG"

helm status "$release_name" --namespace "$namespace"
