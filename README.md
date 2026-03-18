# One File to Rule Them All

Single-file scripts for spinning up complicated things fast.

---

## Scripts

### `face_fusion_setup_on_azure.sh`

Provisions a full GPU-accelerated [FaceFusion](https://github.com/facefusion/facefusion-docker) environment on Azure from scratch.

**What it does:**
- Creates an Azure resource group, storage account (blob), and managed identity
- Spins up an `Standard_NC4as_T4_v3` VM (NVIDIA T4 GPU) with Ubuntu 22.04
- Uses cloud-init to install git, Docker, tmux, nvtop, etc. on first boot
- Generates and uploads helper scripts to the VM:
  - `setup.sh` — installs NVIDIA drivers (535), NVIDIA Container Toolkit, Azure CLI, and clones the FaceFusion Docker repo
  - `start_facefusion.sh` — starts the FaceFusion container (CUDA, port 7860)
  - `sync_workspace.sh` — pulls input files from blob storage via managed identity
  - `upload_outputs.sh` — pushes output files back to blob storage
  - `docker-compose.override.yml` — mounts the local workspace and exposes the Gradio UI
  - `.bashrc_ff` — convenience aliases (`ff`, `pull-data`, `push-outputs`, `gpu`, etc.)

**Usage:**
```bash
# Stand up the full environment
./face_fusion_setup_on_azure.sh up

# Destroy the VM (preserves blob storage)
./face_fusion_setup_on_azure.sh down

# Delete everything including the resource group and all blobs
./face_fusion_setup_on_azure.sh purge
```

**Prerequisites:** Azure CLI logged in (`az login`), SSH key at `~/.ssh/id_rsa`.

**After `up` completes:**
1. SSH in and run `~/setup.sh` (installs drivers, reboots)
2. SSH back in and run `ff` to start FaceFusion
3. On your local machine: `ssh -L 7860:localhost:7860 ff_admin@<VM_IP>`
4. Open `http://localhost:7860`
