#!/usr/bin/env bash
set -e

# ===== CONFIG =====

RESOURCE_GROUP="ctfd-rg"
LOCATION="eastus2"

VM_NAME="ctfd-vm"
VM_SIZE="Standard_B2s_v2"
ADMIN_USER="ctfd_admin"

STORAGE_ACCOUNT="ctfd$(echo $RESOURCE_GROUP | md5sum | head -c6)"
CONTAINER_NAME="challenges"
IDENTITY_NAME="ctfd-identity"

CLOUD_INIT_FILE="cloud-init-ctfd.yaml"

# ===== CLOUD INIT =====

create_cloud_init() {
cat > $CLOUD_INIT_FILE <<EOF
#cloud-config

package_update: true
package_upgrade: false

packages:
  - git
  - tmux
  - htop
  - curl
  - wget
  - docker.io
  - docker-compose-v2
  - python3-pip
  - unzip

runcmd:
  - usermod -aG docker ${ADMIN_USER}
  - chown -R ${ADMIN_USER}:${ADMIN_USER} /home/${ADMIN_USER}
EOF
}

# ===== GENERATE SCRIPTS LOCALLY =====

generate_scripts() {
  mkdir -p .ctfd_scripts

  # --- setup.sh -----------------------------------------------------------
  cat > .ctfd_scripts/setup.sh <<EOF
#!/bin/bash
set -e
echo ""
echo "======================================================"
echo "  CTFd Setup"
echo "======================================================"

echo "[1/3] Clearing apt locks..."
sudo systemctl disable --now unattended-upgrades apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
sudo systemctl kill --kill-who=all apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
while sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
  echo "  Waiting for dpkg lock..."
  sleep 3
done

echo "[2/3] Installing Azure CLI..."
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

echo "[3/3] Cloning CTFd..."
git clone https://github.com/CTFd/CTFd.git \$HOME/ctfd

echo ""
echo "Setup complete! Run 'ctfd-start' to launch."
echo ""
EOF

  # --- start_ctfd.sh ------------------------------------------------------
  cat > .ctfd_scripts/start_ctfd.sh <<EOF
#!/bin/bash
set -e
cd \$HOME/ctfd
echo "Starting CTFd..."
echo "(First run pulls images, may take a few minutes)"
sudo docker compose up -d
echo ""
echo "CTFd is up. Open: http://\$(curl -s ifconfig.me):8000"
echo ""
EOF

  # --- stop_ctfd.sh -------------------------------------------------------
  cat > .ctfd_scripts/stop_ctfd.sh <<EOF
#!/bin/bash
set -e
cd \$HOME/ctfd
sudo docker compose down
echo "CTFd stopped."
EOF

  # --- sync_challenges.sh -------------------------------------------------
  cat > .ctfd_scripts/sync_challenges.sh <<EOF
#!/bin/bash
set -e
TMP="/tmp/cowbell-ctf-challenges.zip"
DEST="\$HOME/cowbell-ctf-challenges"

echo "Authenticating via Managed Identity..."
az login --identity --allow-no-subscriptions -o none

echo "Downloading challenges archive from blob storage..."
az storage blob download \
  --account-name ${STORAGE_ACCOUNT} \
  --container-name ${CONTAINER_NAME} \
  --name cowbell-ctf-challenges.zip \
  --file "\$TMP" \
  --auth-mode login

echo "Extracting..."
rm -rf "\$DEST"
unzip -q "\$TMP" -d "\$HOME"
rm "\$TMP"

echo "Done. Challenges at: \$DEST"
ls -lh "\$DEST"
EOF

  # --- add_challenges.sh --------------------------------------------------
  # Uses a quoted heredoc so $-signs are written verbatim — no escaping needed.
  cat > .ctfd_scripts/add_challenges.sh <<'INNER'
#!/usr/bin/env bash
set -e

# ── config ────────────────────────────────────────────────────────────────────
CHALLENGES_DIR="${1:-$HOME/cowbell-ctf-challenges}"
CTFD_URL="${CTFD_URL:-}"
CTFD_TOKEN="${CTFD_TOKEN:-}"
# ─────────────────────────────────────────────────────────────────────────────

if [[ -z "$CTFD_URL" ]]; then
  read -rp "CTFd URL (e.g. http://localhost:8000): " CTFD_URL
fi
if [[ -z "$CTFD_TOKEN" ]]; then
  read -rsp "CTFd Admin Token: " CTFD_TOKEN
  echo
fi

if ! command -v ctf &>/dev/null; then
  echo "[*] ctfcli not found — installing..."
  pip3 install ctfcli --quiet
  export PATH="$HOME/.local/bin:$PATH"
fi

cd "$CHALLENGES_DIR"

mkdir -p .ctf
cat > .ctf/config <<EOF
[config]
url = ${CTFD_URL}
access_token = ${CTFD_TOKEN}

[challenges]
EOF

echo "[*] Scanning for challenges in $CHALLENGES_DIR..."

challenge_dirs=()
while IFS= read -r yml; do
  challenge_dirs+=("$(dirname "$yml")")
done < <(find . -name "challenge.yml" -not -path "./.ctf/*")

if [[ ${#challenge_dirs[@]} -eq 0 ]]; then
  echo "[!] No challenge.yml files found. Exiting."
  exit 1
fi

echo "[*] Found ${#challenge_dirs[@]} challenge(s):"
for d in "${challenge_dirs[@]}"; do
  echo "    $d"
done

echo
echo "[*] Adding challenges to ctfcli config..."
for d in "${challenge_dirs[@]}"; do
  ctf challenge add "$d"
done

echo
echo "[*] Installing all challenges to CTFd..."
ctf challenge install

echo
echo "[✓] Done! All challenges are now live on $CTFD_URL"
INNER

  # --- .bashrc_ctfd -------------------------------------------------------
  cat > .ctfd_scripts/.bashrc_ctfd <<EOF
export TERM=xterm-256color
export COLORTERM=truecolor
export PATH="\$HOME/.local/bin:\$PATH"
export LS_COLORS='di=01;34:ln=01;36:ex=01;32'
alias ls='ls --color=auto'
alias ll='ls -lh --color=auto'

alias cdctfd='cd \$HOME/ctfd'
alias cdchallenges='cd \$HOME/cowbell-ctf-challenges'
alias dockers='sudo docker ps'

alias ctfd-start='\$HOME/start_ctfd.sh'
alias ctfd-stop='\$HOME/stop_ctfd.sh'
alias pull-challenges='\$HOME/sync_challenges.sh'
alias add-challenges='\$HOME/add_challenges.sh'

ctfd-logs() {
  cd \$HOME/ctfd && sudo docker compose logs -f
}

ctfd-restart() {
  cd \$HOME/ctfd && sudo docker compose restart
}

ctfd-help() {
  echo ""
  echo " -- CTFd -------------------------------------------"
  echo "  ctfd-start          Start CTFd (port 8000)"
  echo "  ctfd-stop           Stop CTFd"
  echo "  ctfd-restart        Restart containers"
  echo "  ctfd-logs           Tail container logs"
  echo "  dockers             View running containers"
  echo ""
  echo " -- Challenges -------------------------------------"
  echo "  pull-challenges     Download challenges from blob"
  echo "  add-challenges      Push challenges into CTFd"
  echo ""
}
EOF

  chmod +x .ctfd_scripts/setup.sh
  chmod +x .ctfd_scripts/start_ctfd.sh
  chmod +x .ctfd_scripts/stop_ctfd.sh
  chmod +x .ctfd_scripts/sync_challenges.sh
  chmod +x .ctfd_scripts/add_challenges.sh
}

# ===== UPLOAD SCRIPTS VIA SCP =====

upload_scripts() {
  local VM_IP=$1
  echo "Waiting for SSH to become available..."
  until ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes \
      ${ADMIN_USER}@${VM_IP} "exit" 2>/dev/null; do
    printf "."
    sleep 5
  done
  echo ""
  echo "Uploading scripts to VM..."

  scp -o StrictHostKeyChecking=no \
    .ctfd_scripts/setup.sh \
    .ctfd_scripts/start_ctfd.sh \
    .ctfd_scripts/stop_ctfd.sh \
    .ctfd_scripts/sync_challenges.sh \
    .ctfd_scripts/add_challenges.sh \
    .ctfd_scripts/.bashrc_ctfd \
    ${ADMIN_USER}@${VM_IP}:~/

  ssh -o StrictHostKeyChecking=no ${ADMIN_USER}@${VM_IP} \
    "grep -q bashrc_ctfd ~/.bashrc || echo -e '\n[[ -f \$HOME/.bashrc_ctfd ]] && source \$HOME/.bashrc_ctfd' >> ~/.bashrc"

  echo "Scripts uploaded."
}

# ===== STORAGE =====

ensure_storage() {
  echo "Checking storage account..."
  if az storage account show --name $STORAGE_ACCOUNT --resource-group $RESOURCE_GROUP &>/dev/null; then
    echo "Storage account already exists."
  else
    echo "Creating storage account..."
    az storage account create \
      --name $STORAGE_ACCOUNT \
      --resource-group $RESOURCE_GROUP \
      --location $LOCATION \
      --sku Standard_LRS
  fi
  ACCOUNT_KEY=$(az storage account keys list \
    --account-name $STORAGE_ACCOUNT \
    --resource-group $RESOURCE_GROUP \
    --query '[0].value' -o tsv)
  echo "Ensuring blob container exists..."
  az storage container create \
    --name $CONTAINER_NAME \
    --account-name $STORAGE_ACCOUNT \
    --account-key $ACCOUNT_KEY \
    --auth-mode key >/dev/null
}

# ===== IDENTITY =====

ensure_identity() {
  if az identity show --name $IDENTITY_NAME --resource-group $RESOURCE_GROUP &>/dev/null; then
    echo "Identity exists."
  else
    echo "Creating managed identity..."
    az identity create --name $IDENTITY_NAME --resource-group $RESOURCE_GROUP
  fi
  PRINCIPAL_ID=$(az identity show \
    --name $IDENTITY_NAME \
    --resource-group $RESOURCE_GROUP \
    --query principalId -o tsv)
  STORAGE_ID=$(az storage account show \
    --name $STORAGE_ACCOUNT \
    --resource-group $RESOURCE_GROUP \
    --query id -o tsv)
  echo "Assigning Storage Blob Data Reader to identity..."
  az role assignment create \
    --assignee-object-id $PRINCIPAL_ID \
    --assignee-principal-type ServicePrincipal \
    --role "Storage Blob Data Reader" \
    --scope $STORAGE_ID \
    --only-show-errors || true
}

# ===== VM =====

create_vm() {
  if az vm show --name $VM_NAME --resource-group $RESOURCE_GROUP &>/dev/null; then
    echo "VM already exists."
    return
  fi

  echo "Creating VM..."

  IDENTITY_ID=$(az identity show \
    --name $IDENTITY_NAME \
    --resource-group $RESOURCE_GROUP \
    --query id -o tsv)

  generate_scripts
  create_cloud_init

  az vm create \
    --resource-group $RESOURCE_GROUP \
    --name $VM_NAME \
    --image Ubuntu2204 \
    --size $VM_SIZE \
    --location $LOCATION \
    --admin-username $ADMIN_USER \
    --generate-ssh-keys \
    --assign-identity $IDENTITY_ID \
    --custom-data $CLOUD_INIT_FILE \
    --security-type Standard \
    --enable-secure-boot false

  az vm open-port --resource-group $RESOURCE_GROUP --name $VM_NAME --port 8000

  VM_IP=$(az vm show \
    --resource-group $RESOURCE_GROUP \
    --name $VM_NAME \
    --show-details \
    --query publicIps -o tsv)

  upload_scripts $VM_IP

  echo ""
  echo "VM ready. Public IP: $VM_IP"
  echo ""
  echo "Upload your challenge files from LOCAL with:"
  echo "  az storage blob upload-batch \\"
  echo "    --account-name ${STORAGE_ACCOUNT} \\"
  echo "    --destination ${CONTAINER_NAME} \\"
  echo "    --source ./cowbell-ctf-challenges"
  echo ""
  echo "Cloud-init is still running in the background (~2 min)."
  echo "Watch progress with:"
  echo "  ssh ${ADMIN_USER}@${VM_IP} 'sudo tail -f /var/log/cloud-init-output.log'"
  echo ""
  echo "Once cloud-init finishes, SSH in and run:"
  echo "  ssh ${ADMIN_USER}@${VM_IP}"
  echo "  ~/setup.sh"
  echo "  ctfd-start"
  echo ""
  echo "Then pull your challenges and load them:"
  echo "  pull-challenges"
  echo "  add-challenges"
  echo ""
  echo "CTFd will be accessible at: http://${VM_IP}:8000"
}

# ===== DESTROY VM =====

destroy_vm() {
  echo ""
  echo "WARNING: This will destroy the VM and all CTFd data."
  echo "(Blob storage and challenges are preserved.)"
  echo ""
  read -rp "Type YES to continue: " confirm
  [[ "$confirm" == "YES" ]] || { echo "Aborted."; exit 1; }

  if az vm show --name $VM_NAME --resource-group $RESOURCE_GROUP &>/dev/null; then
    az vm delete --resource-group $RESOURCE_GROUP --name $VM_NAME --yes
  fi

  DISK_NAME=$(az disk list \
    --resource-group $RESOURCE_GROUP \
    --query "[?starts_with(name, '${VM_NAME}_OsDisk')].name" -o tsv)
  [[ -n "$DISK_NAME" ]] && az disk delete \
    --resource-group $RESOURCE_GROUP \
    --name "$DISK_NAME" \
    --yes

  az network nic delete --resource-group $RESOURCE_GROUP --name "${VM_NAME}VMNic" 2>/dev/null || true
  az network nsg delete --resource-group $RESOURCE_GROUP --name "${VM_NAME}NSG" 2>/dev/null || true
  az network public-ip delete --resource-group $RESOURCE_GROUP --name "${VM_NAME}PublicIP" 2>/dev/null || true
  az network vnet delete --resource-group $RESOURCE_GROUP --name "${VM_NAME}VNET" 2>/dev/null || true
  echo "Compute teardown complete. Blob storage is intact."
}

# ===== PURGE EVERYTHING =====

purge_all() {
  echo ""
  echo "WARNING: Deletes ENTIRE resource group including all blob data."
  read -rp "Type YES to continue: " confirm
  [[ "$confirm" == "YES" ]] || { exit 1; }
  az group delete --name $RESOURCE_GROUP --yes --no-wait
}

# ===== ENTRYPOINT =====

case "$1" in
  up)
    az group create --name $RESOURCE_GROUP --location $LOCATION >/dev/null
    ensure_storage
    ensure_identity
    create_vm
    ;;
  down) destroy_vm ;;
  purge) purge_all ;;
  *) echo "Usage: ./ctfd_setup_on_azure.sh [up|down|purge]" ;;
esac
