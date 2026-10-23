# Running on RunPod

Working notes for running `inference.py` on a rented RunPod GPU, written 2026-10-23.
**Status: not tried yet.** This is the plan, not a verified recipe; update it with what
actually happened.

## Why RunPod

Inference doesn't work on the local machine (RTX 4090 under WSL2). WSL leaves only 22.45 GiB
of VRAM free, generation needs about 22.18 GB plus fragmentation headroom, and the overflow
spills into system RAM, where generation stalls for hours. Full details are in
[wsl-gpu-notes.md](wsl-gpu-notes.md). On native Linux the same 4090 is expected to work; see
the benchmark in [inference_performance.md](inference_performance.md).

## Pod settings

| | |
|---|---|
| GPU | 48 GB card preferred (L40S, RTX 6000 Ada, A6000); 4090 / 5090 also fine |
| CUDA | filter for **12.8 or newer** (torch 2.8 wheels in `requirements.txt` are cu128) |
| Template | any recent "RunPod PyTorch"; the venv installs its own torch |
| Volume disk | about **80 GB** at `/workspace` (models 21 GB, venv about 10 GB, outputs) |
| Access | "SSH over exposed TCP", with your public key added under Settings → SSH Public Keys |

Only `/workspace` survives a pod restart. A Network Volume survives terminating the pod but is
tied to one region.

The dev container (`.devcontainer/`) isn't used on the pod. Its outbound firewall is for local
development and isn't needed here.

## Setup

```bash
apt-get update && apt-get install -y ffmpeg git-lfs libgl1 libglib2.0-0
curl -LsSf https://astral.sh/uv/install.sh | sh && source $HOME/.local/bin/env

cd /workspace
git clone -b add-devcontainer https://github.com/jessekirbs/4DAnyone.git
cd 4DAnyone
git submodule update --init third_party/GVHMR

export HF_HOME=/workspace/.cache/huggingface UV_CACHE_DIR=/workspace/.cache/uv
uv venv --python 3.11 .venv
uv pip install --python .venv/bin/python -r requirements.txt -r requirements-gui.txt
source .venv/bin/activate

python scripts/download_model.py     # about 21 GB
python scripts/download_example.py
python -c "import torch; print(torch.cuda.get_device_name(), torch.cuda.is_available())"
```

Put the `export HF_HOME=...` line in `~/.bashrc` on the pod, or later shells will download
the models again into the container disk.

### SMPL-X

SMPL-X is licensed separately, so copy `models/body_models/smplx/SMPLX_NEUTRAL.npz` from the
local machine instead of downloading it again:

```bash
# local machine
runpodctl send models/body_models/smplx/SMPLX_NEUTRAL.npz

# pod
mkdir -p models/body_models/smplx && cd models/body_models/smplx
runpodctl receive <code> && cd /workspace/4DAnyone
python scripts/download_smplx.py     # finds the file and creates the GVHMR links
```

## Test run

Same clip and settings as the WSL tests, so results are comparable:

```bash
python inference.py --video_path data/source/pexels/7017803-hd_1080_1920_30fps.mp4 \
  --output_dir outputs/runpod1 --views_per_layer 6 2>&1 | tee outputs/runpod1.log
```

- Don't set `PYTORCH_CUDA_ALLOC_CONF`. The `expandable_segments:False` workaround only matters
  under WSL; on native Linux the default (expandable segments on for 24 GB-class GPUs) is what
  the benchmark used.
- Generation should get past `Generate 6 target views: 0/4` within a few minutes. If it sits
  there, watch `nvidia-smi` for VRAM and utilisation.
- Timings and peak memory are written to `outputs/runpod1/metadata.json`; compare them with
  [inference_performance.md](inference_performance.md).
- If `download_example.py` didn't fetch the clip, copy it over with `runpodctl send`.

## Results and the GUI

```bash
# pod
cd outputs && tar czf runpod1.tgz runpod1 && runpodctl send runpod1.tgz
```

For the GUI, run `python app.py --output_dir outputs/runpod1 --server_port 7860` on the pod,
then forward the port from the local machine:
`ssh -N -L 7860:127.0.0.1:7860 root@<ip> -p <port>`.

## Cost

Stop the pod when idle; a stopped pod still bills for its volume. Terminate it to stop all
charges, which also deletes the volume unless it's a Network Volume.

## Claude Code on the pod (optional)

To get help on the pod itself, install Claude Code there and point it at this file:

```bash
curl -fsSL https://claude.ai/install.sh | bash
cd /workspace/4DAnyone && claude
```

Sign in when prompted. The pod session doesn't share history with the local one, so start by
asking it to read `docs/runpod.md` and `docs/wsl-gpu-notes.md`.

## Runpod agent plugin (not used)

Runpod's agent guide (https://agents.runpod.io/) installs a Claude Code plugin plus the hosted
MCP server `mcp.runpod.io` (OAuth sign-in, no API key stored). It manages pods (create, stop,
list, costs) but can't run commands inside a pod. Skipped for now in favour of the manual steps
above. Using it from the dev container would need `mcp.runpod.io` added to
`.devcontainer/allowed-domains.txt`.
