#!/usr/bin/env bash
set -eu

# =============================================================================
# 3x-ui Modular Node Deploy — GitHub Bootstrap Loader
# Запуск:
#   bash <(curl -fsSL https://raw.githubusercontent.com/vaalaav/SuperTurbo3XUI-2/main/bootstrap.sh)
# Переменные окружения (опционально):
#   GH_REPO="user/repo"   GH_BRANCH="main"   GH_TOKEN="ghp_..."
# =============================================================================

GH_REPO="${GH_REPO:-vaalaav/SuperTurbo3XUI-2}"
DEFAULT_REPO="${GH_REPO}"
BRANCH="${GH_BRANCH:-main}"
INSTALL_DIR="${INSTALL_DIR:-/opt/3xui-node}"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; NC='\033[0m'

[[ $EUID -eq 0 ]] || { echo -e "${RED}[ERR] Запустите от имени root.${NC}"; exit 1; }

if [[ -z "$DEFAULT_REPO" ]]; then
    echo -e "${YELLOW}[WARN] Не указан GH_REPO в bootstrap.sh.${NC}"
    read -erp "Введите GitHub repo (user/repo): " DEFAULT_REPO
fi

command -v curl >/dev/null 2>&1 || { DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 update -qq && DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 install -y -qq curl; }
command -v tar  >/dev/null 2>&1 || { DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 update -qq && DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 install -y -qq tar; }

TAR_URL="https://github.com/${DEFAULT_REPO}/archive/refs/heads/${BRANCH}.tar.gz"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

echo -e "${CYAN}[INFO] Загрузка ${DEFAULT_REPO} (${BRANCH})...${NC}"
CURL_ARGS=(-fsSL --retry 3 --max-time 60)
if [[ -n "${GH_TOKEN:-}" ]]; then
    CURL_ARGS+=(-H "Authorization: Bearer ${GH_TOKEN}")
    TAR_URL="https://api.github.com/repos/${DEFAULT_REPO}/tarball/${BRANCH}"
fi

curl "${CURL_ARGS[@]}" "$TAR_URL" -o "${TMP_DIR}/repo.tar.gz"
tar -xzf "${TMP_DIR}/repo.tar.gz" -C "$TMP_DIR"

SRC_DIR=$(find "$TMP_DIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)
[[ -n "$SRC_DIR" && -f "${SRC_DIR}/install.sh" ]] || {
    echo -e "${RED}[ERR] Некорректная структура архива репозитория.${NC}"
    exit 1
}

mkdir -p "$INSTALL_DIR"
find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
cp -a "${SRC_DIR}/." "$INSTALL_DIR/"

cat <<EOF > "${INSTALL_DIR}/.repo"
GH_REPO="${DEFAULT_REPO}"
GH_BRANCH=${BRANCH}
UPDATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

chmod +x "${INSTALL_DIR}/bootstrap.sh" \
         "${INSTALL_DIR}/install.sh" \
         "${INSTALL_DIR}/modules/"*.sh \
         "${INSTALL_DIR}/lib/"*.py \
         "${INSTALL_DIR}/cli/my3xui" \
         "${INSTALL_DIR}/cli/3xui-node-geo-update"

echo -e "${GREEN}[OK] Проект развёрнут в ${INSTALL_DIR}${NC}"
exec bash "${INSTALL_DIR}/install.sh" "$@"
