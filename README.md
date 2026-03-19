# One File to Rule Them All

Single-file scripts for spinning up complicated things fast.

---

## Scripts

### `ctfd_setup_on_azure.sh`

Provisions a [CTFd](https://github.com/CTFd/CTFd) instance on Azure for running a Capture The Flag competition.

**What it does:**
- Creates an Azure resource group, storage account (blob), and managed identity
- Spins up a `Standard_D2s_v3` VM (2 vCPU, 8 GB RAM) with the managed identity attached
- The identity gets `Storage Blob Data Reader` on the storage account so the VM can pull challenge files without any credentials
- Uses cloud-init to install Docker, python3-pip, and dependencies on first boot
- Generates and uploads helper scripts to the VM:
  - `setup.sh` — installs Azure CLI and clones the CTFd repo
  - `start_ctfd.sh` — starts CTFd + MariaDB + Redis via `docker compose` (port 8000)
  - `stop_ctfd.sh` — tears down the containers
  - `sync_challenges.sh` — pulls the `cowbell-ctf-challenges` folder from blob storage to `$HOME`
  - `add_challenges.sh` — uses `ctfcli` to register and push all challenges into a live CTFd instance
  - `.bashrc_ctfd` — convenience aliases (`ctfd-start`, `ctfd-stop`, `ctfd-logs`, `pull-challenges`, `add-challenges`)

**Usage:**
```bash
# Stand up the environment
./ctfd_setup_on_azure.sh up

# Destroy the VM (all CTFd data is lost)
./ctfd_setup_on_azure.sh down

# Delete everything including the resource group
./ctfd_setup_on_azure.sh purge
```

**Prerequisites:** Azure CLI logged in (`az login`), SSH key at `~/.ssh/id_rsa`.

**After `up` completes:**
1. Upload your challenge zip from local (the blob name must be `cowbell-ctf-challenges`):
   ```
   az storage blob upload --account-name <STORAGE_ACCOUNT> --container-name challenges --name cowbell-ctf-challenges --file ./cowbell-ctf-challenges.zip
   ```
2. SSH in and run `~/setup.sh` (installs Azure CLI, clones CTFd)
3. Run `ctfd-start` to launch the containers
4. Open `http://<VM_IP>:8000` — first visit walks you through admin setup, get your API token from the admin panel
5. Run `pull-challenges` to download challenges from blob, then `add-challenges` to push them into CTFd

**Note:** `down` preserves blob storage — only the VM is destroyed. `purge` deletes everything.

---

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
