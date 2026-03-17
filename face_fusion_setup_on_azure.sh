#!/usr/bin/env bash
set -e

# ===== CONFIG =====

RESOURCE_GROUP="facefusion-rg"
LOCATION="eastus"

VM_NAME="facefusion-vm"
VM_SIZE="Standard_NC4as_T4_v3"
ADMIN_USER="ff_admin"

STORAGE_ACCOUNT="ffusion$(echo $RESOURCE_GROUP | md5sum | head -c6)"
CONTAINER_NAME="workspace"
IDENTITY_NAME="facefusion-identity"

CLOUD_INIT_FILE="cloud-init-facefusion.yaml"

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
  - nvtop
  - docker.io
  - docker-compose-v2

runcmd:
  - usermod -aG docker ${ADMIN_USER}
  - mkdir -p /home/${ADMIN_USER}/workspace/inputs
  - mkdir -p /home/${ADMIN_USER}/workspace/outputs
  - chown -R ${ADMIN_USER}:${ADMIN_USER} /home/${ADMIN_USER}
EOF
}

# ===== GENERATE SCRIPTS LOCALLY =====

generate_scripts() {
  mkdir -p .ff_scripts

  # --- setup.sh -----------------------------------------------------------
  cat > .ff_scripts/setup.sh <<EOF
#!/bin/bash
set -e
echo ""
echo "======================================================"
echo "  FaceFusion GPU Setup"
echo "======================================================"

# -- Kill unattended-upgrades so it doesn't hold the dpkg lock
echo "[1/7] Clearing apt locks..."
sudo systemctl disable --now unattended-upgrades apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
sudo systemctl kill --kill-who=all apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
while sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
  echo "  Waiting for dpkg lock..."
  sleep 3
done

# -- NVIDIA drivers
echo "[2/7] Installing NVIDIA drivers..."
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
sudo apt-get install -y --no-install-recommends nvidia-headless-535-server nvidia-utils-535-server

# -- NVIDIA Container Toolkit
echo "[3/7] Installing NVIDIA Container Toolkit..."
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | sudo gpg --yes --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit
sudo systemctl restart docker

# -- Azure CLI
echo "[4/7] Installing Azure CLI..."
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# -- Clone FaceFusion
echo "[5/7] Cloning FaceFusion Docker repo..."
git clone https://github.com/facefusion/facefusion-docker.git \$HOME/facefusion

# -- Copy override into cloned repo
echo "[6/7] Installing docker-compose override..."
cp \$HOME/docker-compose.override.yml \$HOME/facefusion/docker-compose.override.yml

# -- Final ownership fix + reboot
echo "[7/7] Fixing ownership and rebooting..."
sudo chown -R ${ADMIN_USER}:${ADMIN_USER} \$HOME
echo ""
echo "Setup complete! Rebooting to load NVIDIA kernel module..."
echo "SSH back in after ~30s and run 'ff' to start FaceFusion."
echo ""
sudo reboot
EOF

  # --- start_facefusion.sh ------------------------------------------------
  cat > .ff_scripts/start_facefusion.sh <<EOF
#!/bin/bash
set -e
cd \$HOME/facefusion
echo "Starting FaceFusion via Docker..."
echo "(The first run takes a few minutes to pull the CUDA image)"
docker compose -f docker-compose.cuda.yml -f docker-compose.override.yml up
EOF

  # --- sync_workspace.sh --------------------------------------------------
  cat > .ff_scripts/sync_workspace.sh <<EOF
#!/bin/bash
set -e
INPUTS_DIR="\$HOME/workspace/inputs"
mkdir -p "\$INPUTS_DIR"

echo "Authenticating via Managed Identity..."
az login --identity --allow-no-subscriptions -o none

echo "Syncing inputs from blob storage..."
az storage blob download-batch \
  --account-name ${STORAGE_ACCOUNT} \
  --source ${CONTAINER_NAME} \
  --pattern "inputs/*" \
  --destination "\$INPUTS_DIR" \
  --auth-mode login

echo "Done. Inputs contents:"
ls -lh "\$INPUTS_DIR"
EOF

  # --- upload_outputs.sh --------------------------------------------------
  cat > .ff_scripts/upload_outputs.sh <<EOF
#!/bin/bash
set -e
OUTPUTS_DIR="\$HOME/workspace/outputs"
mkdir -p "\$OUTPUTS_DIR"

echo "Authenticating via Managed Identity..."
az login --identity --allow-no-subscriptions -o none

echo "Uploading FaceFusion outputs to blob storage..."
az storage blob upload-batch \
  --account-name ${STORAGE_ACCOUNT} \
  --destination ${CONTAINER_NAME} \
  --destination-path outputs \
  --source "\$OUTPUTS_DIR" \
  --auth-mode login \
  --overwrite

echo "Upload complete."
EOF

  # --- docker-compose.override.yml ----------------------------------------
  cat > .ff_scripts/docker-compose.override.yml <<EOF
services:
  facefusion-cuda:
    ports:
      - "7860:7860"
    volumes:
      - /home/${ADMIN_USER}/workspace:/facefusion/workspace
      - /home/${ADMIN_USER}/facefusion/core.py:/facefusion/facefusion/core.py
      - /home/${ADMIN_USER}/facefusion/content_analyser.py:/facefusion/facefusion/content_analyser.py
    environment:
      - GRADIO_SERVER_NAME=0.0.0.0
      - GRADIO_SERVER_PORT=7860
EOF

  # --- .bashrc_ff ---------------------------------------------------------
  cat > .ff_scripts/.bashrc_ff <<EOF
export TERM=xterm-256color
export COLORTERM=truecolor
export LS_COLORS='di=01;34:ln=01;36:ex=01;32:*.mp4=01;35:*.jpg=01;35:*.png=01;35'
alias ls='ls --color=auto'
alias ll='ls -lh --color=auto'

alias cdff='cd \$HOME/facefusion'
alias cdwork='cd \$HOME/workspace'
alias cdin='cd \$HOME/workspace/inputs'
alias cdout='cd \$HOME/workspace/outputs'

alias gpu='nvidia-smi'
alias dockers='docker ps'

alias ff='\$HOME/start_facefusion.sh'
alias pull-data='\$HOME/sync_workspace.sh'
alias push-outputs='\$HOME/upload_outputs.sh'

ff-help() {
  echo ""
  echo " -- FaceFusion (Docker) ----------------------------"
  echo "  ff            Start the container (port 7860)"
  echo "  dockers       View running containers"
  echo ""
  echo " -- Data & Storage ---------------------------------"
  echo "  pull-data     Download inputs/ from Blob"
  echo "  push-outputs  Upload outputs/ back to Blob"
  echo "  cdin / cdout  Navigate workspace folders"
  echo ""
}
EOF

  # --- README.md ----------------------------------------------------------
  cat > .ff_scripts/README.md <<EOF
# FaceFusion Docker on Azure T4

## First-time setup
Cloud-init handles basic packages on first boot (~2 min).
Once it finishes, run the setup script to install drivers and FaceFusion:

  ~/setup.sh

Watch cloud-init progress with:
  sudo tail -f /var/log/cloud-init-output.log

## Normal usage

Step 1 - (Optional) Pull source faces / target videos from blob:
  ~/sync_workspace.sh

Step 2 - Start FaceFusion:
  ff

Step 3 - On YOUR LOCAL machine, open the SSH tunnel:
  ssh -L 7860:localhost:7860 ${ADMIN_USER}@<VM_PUBLIC_IP>
  Then open: http://localhost:7860

## Notes on the Docker setup
Your local ~/workspace folder is mounted into the container.
Files appear inside the container under /facefusion/workspace.
EOF

  chmod +x .ff_scripts/setup.sh
  chmod +x .ff_scripts/start_facefusion.sh
  chmod +x .ff_scripts/sync_workspace.sh
  chmod +x .ff_scripts/upload_outputs.sh
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
    .ff_scripts/setup.sh \
    .ff_scripts/start_facefusion.sh \
    .ff_scripts/sync_workspace.sh \
    .ff_scripts/upload_outputs.sh \
    .ff_scripts/docker-compose.override.yml \
    .ff_scripts/.bashrc_ff \
    .ff_scripts/README.md \
    ${ADMIN_USER}@${VM_IP}:~/

  # Wire .bashrc_ff into .bashrc
  ssh -o StrictHostKeyChecking=no ${ADMIN_USER}@${VM_IP} \
    "grep -q bashrc_ff ~/.bashrc || echo -e '\n[[ -f \$HOME/.bashrc_ff ]] && source \$HOME/.bashrc_ff' >> ~/.bashrc"

  echo "Scripts uploaded."
}

# ===== STORAGE =====

ensure_storage() {
  echo "Checking storage account..."
  if az storage account show --name $STORAGE_ACCOUNT --resource-group $RESOURCE_GROUP &>/dev/null; then
    echo "Storage account already exists."
  else
    echo "Creating storage account..."
    az storage account create --name $STORAGE_ACCOUNT --resource-group $RESOURCE_GROUP --location $LOCATION --sku Standard_LRS
  fi
  ACCOUNT_KEY=$(az storage account keys list --account-name $STORAGE_ACCOUNT --resource-group $RESOURCE_GROUP --query '[0].value' -o tsv)
  echo "Ensuring blob container exists..."
  az storage container create --name $CONTAINER_NAME --account-name $STORAGE_ACCOUNT --account-key $ACCOUNT_KEY --auth-mode key >/dev/null
}

# ===== IDENTITY =====

ensure_identity() {
  if az identity show --name $IDENTITY_NAME --resource-group $RESOURCE_GROUP &>/dev/null; then
    echo "Identity exists."
  else
    echo "Creating identity..."
    az identity create --name $IDENTITY_NAME --resource-group $RESOURCE_GROUP
  fi
  PRINCIPAL_ID=$(az identity show --name $IDENTITY_NAME --resource-group $RESOURCE_GROUP --query principalId -o tsv)
  STORAGE_ID=$(az storage account show --name $STORAGE_ACCOUNT --resource-group $RESOURCE_GROUP --query id -o tsv)
  echo "Ensuring blob permissions..."
  az role assignment create --assignee $PRINCIPAL_ID --role "Storage Blob Data Contributor" --scope $STORAGE_ID &>/dev/null || true
}

# ===== VM =====

create_vm() {
  if az vm show --name $VM_NAME --resource-group $RESOURCE_GROUP &>/dev/null; then
    echo "VM already exists."
    return
  fi

  echo "Creating GPU VM..."
  IDENTITY_ID=$(az identity show --name $IDENTITY_NAME --resource-group $RESOURCE_GROUP --query id -o tsv)

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

  az vm open-port --resource-group $RESOURCE_GROUP --name $VM_NAME --port 22

  VM_IP=$(az vm show --resource-group $RESOURCE_GROUP --name $VM_NAME --show-details --query publicIps -o tsv)

  upload_scripts $VM_IP

  echo ""
  echo "VM ready. Public IP: $VM_IP"
  echo ""
  echo "Cloud-init is still running in the background (~2 min)."
  echo "Watch progress with:"
  echo "  ssh ${ADMIN_USER}@${VM_IP} 'sudo tail -f /var/log/cloud-init-output.log'"
  echo ""
  echo "To re-upload scripts manually if needed:"
  echo "  scp -i ~/.ssh/id_rsa .ff_scripts/* ${ADMIN_USER}@${VM_IP}:~/"
  echo ""
  echo "Once cloud-init finishes, SSH in and run:"
  echo "  ssh -i ~/.ssh/id_rsa ${ADMIN_USER}@${VM_IP}"
  echo "  ~/setup.sh"
}

# ===== DESTROY VM =====

destroy_vm() {
  echo ""
  echo "WARNING: This will destroy the VM and all its compute resources."
  echo "Make sure you have uploaded your FaceFusion outputs to blob first:"
  echo "  ssh ${ADMIN_USER}@<IP> '~/upload_outputs.sh'"
  echo ""
  read -rp "Type YES to continue: " confirm
  [[ "$confirm" == "YES" ]] || { echo "Aborted."; exit 1; }

  if az vm show --name $VM_NAME --resource-group $RESOURCE_GROUP &>/dev/null; then
    az vm delete --resource-group $RESOURCE_GROUP --name $VM_NAME --yes
  fi

  DISK_NAME=$(az disk list --resource-group $RESOURCE_GROUP --query "[?starts_with(name, '${VM_NAME}_OsDisk')].name" -o tsv)
  [[ -n "$DISK_NAME" ]] && az disk delete --resource-group $RESOURCE_GROUP --name "$DISK_NAME" --yes

  az network nic delete --resource-group $RESOURCE_GROUP --name "${VM_NAME}VMNic" 2>/dev/null || true
  az network nsg delete --resource-group $RESOURCE_GROUP --name "${VM_NAME}NSG" 2>/dev/null || true
  az network public-ip delete --resource-group $RESOURCE_GROUP --name "${VM_NAME}PublicIP" 2>/dev/null || true
  az network vnet delete --resource-group $RESOURCE_GROUP --name "${VM_NAME}VNET" 2>/dev/null || true
  echo "Compute teardown complete."
}

# ===== PURGE EVERYTHING =====

purge_all() {
  echo ""
  echo "WARNING: Deletes ENTIRE resource group and ALL BLOBS."
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
  *) echo "Usage: ./gpu_env.sh [up|down|purge]" ;;
esac
