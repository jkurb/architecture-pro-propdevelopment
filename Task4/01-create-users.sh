#!/usr/bin/env bash
# 01-create-users.sh — создание пользователей Kubernetes по клиентским x509-сертификатам.
#
# Каждый пользователь:
#   1. Получает RSA-ключ
#   2. Получает CSR с CN=<username> и O=<group> (Kubernetes возьмёт O как группу)
#   3. CSR подписывается CA Minikube → x509-сертификат
#   4. Генерируется отдельный kubeconfig
#
# Использование (после `minikube start`):
#   ./01-create-users.sh
#
# Артефакты складываются в ./certs и ./kubeconfigs (рядом со скриптом).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERT_DIR="${SCRIPT_DIR}/certs"
KUBECONFIG_DIR="${SCRIPT_DIR}/kubeconfigs"
mkdir -p "$CERT_DIR" "$KUBECONFIG_DIR"

# Minikube CA
CA_CRT="${HOME}/.minikube/ca.crt"
CA_KEY="${HOME}/.minikube/ca.key"

if [[ ! -f "$CA_CRT" || ! -f "$CA_KEY" ]]; then
  echo "ERROR: Не найден CA Minikube ($CA_CRT / $CA_KEY)." >&2
  echo "       Сначала выполните 'minikube start'." >&2
  exit 1
fi

# Адрес API-сервера из текущего kubeconfig
APISERVER="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
if [[ -z "$APISERVER" ]]; then
  echo "ERROR: Не удалось определить API server (kubectl config view)." >&2
  exit 1
fi

CLUSTER_NAME="minikube"
CERT_DAYS=365

create_user() {
  local user="$1"
  local group="$2"

  echo "==> Создание пользователя ${user} (группа: ${group})"

  # 1. Private key
  openssl genrsa -out "${CERT_DIR}/${user}.key" 2048 2>/dev/null

  # 2. CSR с CN=user, O=group
  openssl req -new \
    -key "${CERT_DIR}/${user}.key" \
    -out "${CERT_DIR}/${user}.csr" \
    -subj "/CN=${user}/O=${group}"

  # 3. Подпись CA Minikube
  openssl x509 -req \
    -in "${CERT_DIR}/${user}.csr" \
    -CA "${CA_CRT}" \
    -CAkey "${CA_KEY}" \
    -CAcreateserial \
    -out "${CERT_DIR}/${user}.crt" \
    -days "${CERT_DAYS}" \
    -sha256 2>/dev/null

  # 4. kubeconfig
  local kc="${KUBECONFIG_DIR}/${user}.kubeconfig"
  rm -f "$kc"

  kubectl config set-cluster "${CLUSTER_NAME}" \
    --certificate-authority="${CA_CRT}" \
    --embed-certs=true \
    --server="${APISERVER}" \
    --kubeconfig="$kc" >/dev/null

  kubectl config set-credentials "${user}" \
    --client-certificate="${CERT_DIR}/${user}.crt" \
    --client-key="${CERT_DIR}/${user}.key" \
    --embed-certs=true \
    --kubeconfig="$kc" >/dev/null

  kubectl config set-context "${user}@${CLUSTER_NAME}" \
    --cluster="${CLUSTER_NAME}" \
    --user="${user}" \
    --kubeconfig="$kc" >/dev/null

  kubectl config use-context "${user}@${CLUSTER_NAME}" --kubeconfig="$kc" >/dev/null

  echo "    cert: ${CERT_DIR}/${user}.crt"
  echo "    kubeconfig: $kc"
}

# === Пять демо-пользователей по ролевой модели ===
create_user alice    cluster-admins
create_user bob      security
create_user charlie  cluster-viewers
create_user dave     cluster-configurators
create_user eve      sales-developers

echo
echo "Готово. Чтобы войти под пользователем (пример):"
echo "  KUBECONFIG=${KUBECONFIG_DIR}/alice.kubeconfig kubectl get nodes"
echo "  KUBECONFIG=${KUBECONFIG_DIR}/eve.kubeconfig kubectl -n domain-sales get pods"
