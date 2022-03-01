#!/bin/bash
set -e

if [ -f "$SOURCE/$NAMESPACE_OVERWRITE" ]; then
  NAMESPACE=$(cat "$SOURCE/$NAMESPACE_OVERWRITE")
elif [ -n "$NAMESPACE_OVERWRITE" ]; then
  NAMESPACE=$NAMESPACE
fi

setup_kubernetes() {
  local PAYLOAD=$1 SOURCE=$2 KUBECONFIG_RELATIVE KUBECONFIG_TEXT

  KUBECONFIG_RELATIVE=$(jq -r '.params.kubeconfig_path // empty' <$PAYLOAD)
  KUBECONFIG_TEXT=$(jq -r '.source.kubeconfig // empty' <$PAYLOAD)

  if [[ -n "$KUBECONFIG_RELATIVE" && -f "${SOURCE}/${KUBECONFIG_RELATIVE}" ]]; then
    export KUBECONFIG="${SOURCE}/${KUBECONFIG_RELATIVE}"
  elif [ -n "$KUBECONFIG_TEXT" ]; then
    KUBECONFIG=$( mktemp kubeconfig.XXXXXX )
    echo "$KUBECONFIG_TEXT" > "$KUBECONFIG"
    export KUBECONFIG
  else
    # Setup kubectl
    local CLUSTER_URL
    CLUSTER_URL=$(jq -r '.source.cluster_url // ""' <$PAYLOAD)
    if [ -z "$CLUSTER_URL" ]; then
      echo "invalid payload (missing cluster_url)"
      exit 1
    fi
    if [[ "$CLUSTER_URL" =~ https.* ]]; then
      insecure_cluster=$(jq -r '.source.insecure_cluster // "false"' <$PAYLOAD)
      cluster_ca=$(jq -r '.source.cluster_ca // ""' <$PAYLOAD)
      admin_key=$(jq -r '.source.admin_key // ""' <$PAYLOAD)
      admin_cert=$(jq -r '.source.admin_cert // ""' <$PAYLOAD)
      token=$(jq -r '.source.token // ""' <$PAYLOAD)
      token_path=$(jq -r '.params.token_path // ""' <$PAYLOAD)

      if [ "$insecure_cluster" == "true" ]; then
        kubectl config set-cluster default --server="$CLUSTER_URL" --insecure-skip-tls-verify=true
      else
        ca_path="/root/.kube/ca.pem"
        echo "$cluster_ca" | base64 -d >$ca_path
        kubectl config set-cluster default --server="$CLUSTER_URL" --certificate-authority=$ca_path
      fi

      if [ -f "$SOURCE/$token_path" ]; then
        kubectl config set-credentials admin --token="$(cat $SOURCE/$token_path)"
      elif [ ! -z "$token" ]; then
        kubectl config set-credentials admin --token="$token"
      else
        mkdir -p /root/.kube
        key_path="/root/.kube/key.pem"
        cert_path="/root/.kube/cert.pem"
        echo "$admin_key" | base64 -d >$key_path
        echo "$admin_cert" | base64 -d >$cert_path
        kubectl config set-credentials admin --client-certificate=$cert_path --client-key=$key_path
      fi

      kubectl config set-context default --cluster=default --user=admin
    else
      kubectl config set-cluster default --server="$CLUSTER_URL"
      kubectl config set-context default --cluster=default
    fi

    kubectl config use-context default
  fi

  kubectl version
}

setup_helm() {
  # $1 is the name of the PAYLOAD file
  # $2 is the name of the SOURCE directory

  history_max=$(jq -r '.source.helm_history_max // "0"' <$1)

  helm_bin="helm"

  $helm_bin version

  helm_setup_purge_all=$(jq -r '.source.helm_setup_purge_all // "false"' <$1)
  if [ "$helm_setup_purge_all" = "true" ]; then
    local release
    for release in $(helm ls -aq --NAMESPACE $NAMESPACE); do
      helm delete --purge "$release" --NAMESPACE $NAMESPACE
    done
  fi
}

wait_for_service_up() {
  SERVICE=$1
  TIMEOUT=$2
  if [ "$TIMEOUT" -le "0" ]; then
    echo "Service $SERVICE was not ready in time"
    exit 1
  fi
  RESULT=$(kubectl get endpoints --NAMESPACE=$NAMESPACE $SERVICE -o jsonpath={.subsets[].addresses[].targetRef.name} 2>/dev/null || true)
  if [ -z "$RESULT" ]; then
    sleep 1
    wait_for_service_up $SERVICE $((--TIMEOUT))
  fi
}

setup_repos() {
  repos=$(jq -c '(try .source.repos[] catch [][])' <$1)
  plugins=$(jq -c '(try .source.plugins[] catch [][])' <$1)

  local IFS=$'\n'

  if [ "$plugins" ]; then
    for pl in $plugins; do
      plurl=$(echo $pl | jq -cr '.url')
      plversion=$(echo $pl | jq -cr '.version // ""')
      if [ -n "$plversion" ]; then
        $helm_bin plugin install $plurl --version $plversion
      else
        if [ -d $2/$plurl ]; then
          $helm_bin plugin install $2/$plurl
        else
          $helm_bin plugin install $plurl
        fi
      fi
    done
  fi

  if [ "$repos" ]; then
    for r in $repos; do
      name=$(echo $r | jq -r '.name')
      url=$(echo $r | jq -r '.url')
      username=$(echo $r | jq -r '.username // ""')
      password=$(echo $r | jq -r '.password // ""')

      echo Installing helm repository $name $url
      if [[ -n "$username" && -n "$password" ]]; then
        $helm_bin repo add $name $url --username $username --password $password
      else
        $helm_bin repo add $name $url
      fi
    done

    $helm_bin repo update
  fi

  $helm_bin repo add stable https://charts.helm.sh/stable
  $helm_bin repo update
}

setup_resource() {
  tracing_enabled=$(jq -r '.source.tracing_enabled // "false"' <$1)
  if [ "$tracing_enabled" = "true" ]; then
    set -x
  fi

  echo "Initializing kubectl..."
  setup_kubernetes $1 $2
  echo "Initializing helm..."
  setup_helm $1 $2
  setup_repos $1 $2
}