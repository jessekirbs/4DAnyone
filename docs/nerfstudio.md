# 3DGS reconstruction with Nerfstudio

Export one synchronized multi-view frame from 4DAnyone and reconstruct it as a 3D Gaussian Splatting (3DGS) scene with Nerfstudio Splatfacto.

## Installation

Install Nerfstudio in a new environment by following the [official installation guide](https://docs.nerf.studio/quickstart/installation.html), then install:

```bash
pip install huggingface-hub safetensors
```

## Export

Run the exporter in the 4DAnyone inference environment:

```bash
conda activate 4danyone
python scripts/export_nerfstudio.py \
    --data_dir data/fdanyone/pexels/2785536-uhd_2160_3840_25fps \
    --output_dir data/ns_data/pexels/2785536-uhd_2160_3840_25fps/frame_000 \
    --frame_index 0
```

The exported Nerfstudio data is written to:

```bash
data/ns_data/pexels/<clip>/frame_000/
├── transforms.json
├── sparse_pcd.ply                 # visual-hull initialization
├── images/00.png ... <N-1>.png
└── masks/00.png ... <N-1>.png
```

## Train

Standard Splatfacto:

```bash
ns-train splatfacto \
    --data data/ns_data/pexels/2785536-uhd_2160_3840_25fps/frame_000 \
    --output-dir data/ns_outputs/pexels/2785536-uhd_2160_3840_25fps/frame_000 \
    --pipeline.model.background-color random
```

Splatfacto with perceptual loss:

```bash
python scripts/train_nerfstudio.py splatfacto-perceptual \
    --data data/ns_data/pexels/2785536-uhd_2160_3840_25fps/frame_000 \
    --output-dir data/ns_outputs/pexels/2785536-uhd_2160_3840_25fps/frame_000 \
    --pipeline.model.background-color random \
    --pipeline.model.perceptual-loss-weight 0.4 \
    --pipeline.model.perceptual-compute-dtype bfloat16
```

If the GPU supports `bfloat16`, we recommend enabling it to accelerate training.

## Notes: uv venv on Runpod (2026-10-24)

Tested on the Runpod pod from [runpod.md](runpod.md) (RTX 6000 Ada, CUDA 12.8 `nvcc`, Ubuntu 24.04),
with Nerfstudio in its own venv `.venv-ns` instead of conda. Installed versions: nerfstudio 1.1.5,
gsplat 1.4.0, torch 2.8.0+cu128.

```bash
uv venv --python 3.11 .venv-ns
uv pip install --python .venv-ns/bin/python --index-url https://download.pytorch.org/whl/cu128 \
    torch==2.8.0+cu128 torchvision==0.23.0+cu128
printf 'torch==2.8.0+cu128\ntorchvision==0.23.0+cu128\n' > ns-constraints.txt
uv pip install --python .venv-ns/bin/python --index-strategy unsafe-best-match \
    --extra-index-url https://download.pytorch.org/whl/cu128 -c ns-constraints.txt \
    nerfstudio huggingface-hub safetensors fire
apt-get install -y libegl1
```

The export step runs in the main `.venv` (instead of `conda activate 4danyone`). Training and
`ns-export` run in `.venv-ns` with these variables set:

```bash
export PATH=$PWD/.venv-ns/bin:$PATH                         # or: source .venv-ns/bin/activate
export TORCH_EXTENSIONS_DIR=/workspace/.cache/torch_extensions TORCH_CUDA_ARCH_LIST=8.9
```

`TORCH_CUDA_ARCH_LIST=8.9` matches Ada GPUs (RTX 6000 Ada, L40S, RTX 4090). Use `8.6` for an A6000,
`8.0` for an A100, `9.0` for an H100 and `12.0` for an RTX 5090.

Fixes needed:

- **The constraints file keeps torch on cu128.** Without it, Nerfstudio's dependencies can replace the
  torch build.
- **gsplat compiles its CUDA kernels on first use** (about 1 to 2 min). It fails with
  `Ninja is required to load C++ extensions` unless `.venv-ns/bin` is on `PATH`. `ninja` is
  installed in the venv, but torch looks for it on `PATH`. `TORCH_CUDA_ARCH_LIST` limits the build to
  the GPU in use. `TORCH_EXTENSIONS_DIR` keeps the built kernels on the `/workspace` volume.
- **`libEGL.so.1`:** training fails at `import open3d` (loading `sparse_pcd.ply`) with
  `ImportError: libEGL.so.1: cannot open shared object file`. Install `libegl1`.
- **Add `--viewer.quit-on-train-completion True`** to the training command when running it headless.
  Otherwise the viewer keeps running after training finishes.
- **Nested output directory:** `ns-train` puts each run under `<output-dir>/<experiment-name>/` (the
  data folder's name by default), so runs land in `.../frame_000/frame_000/splatfacto-perceptual/<timestamp>/`.

### Export a .ply

```bash
PYTHONPATH=$PWD \
NERFSTUDIO_METHOD_CONFIGS=splatfacto-perceptual=fdanyone.nerfstudio.splatfacto:splatfacto_perceptual_method \
TORCH_FORCE_NO_WEIGHTS_ONLY_LOAD=1 \
ns-export gaussian-splat --load-config <training-output>/config.yml --output-dir <export-dir>
```

- `ns-export` fails with `KeyError: 'splatfacto-perceptual'` unless the custom method is registered.
  `scripts/train_nerfstudio.py` and `scripts/view_nerfstudio.py` do this themselves, but plain
  `ns-export` doesn't. `PYTHONPATH` makes `fdanyone` importable.
- Loading the checkpoint fails under torch 2.6 and newer with `WeightsUnpickler error: Unsupported
  global: GLOBAL numpy._core.multiarray.scalar`. Nerfstudio 1.1.5 calls `torch.load` without
  `weights_only=False`. `TORCH_FORCE_NO_WEIGHTS_ONLY_LOAD=1` restores the old behaviour; use it only
  with checkpoints you trained yourself. `scripts/view_nerfstudio.py` probably hits the same error
  (not tested).

The `.ply` opens in browser splat viewers such as [SuperSplat](https://superspl.at/editor).

### First result

24 views of `7017803-hd_1080_1920_30fps.mp4` (`--views_per_layer 24`, 33 min of inference on the
RTX 6000 Ada), frame 0, splatfacto-perceptual with perceptual weight 0.4 and bf16:

- Export: 24 images and masks, 15,560 visual-hull points.
- Training: 30,000 steps in about 15 min (12 ms/step at first, about 32 ms/step by the end as the
  number of Gaussians grows).
- `.ply` export: 111,057 of 111,678 Gaussians (621 dropped for low opacity), 27.5 MB.

## View

Launch the viewer with the config path printed by training:

```bash
python scripts/view_nerfstudio.py \
    --load-config <training-output>/config.yml
```

Example 3DGS reconstruction in the Nerfstudio viewer:

![Example 3DGS reconstruction in the Nerfstudio viewer](assets/nerfstudio-example.jpg)

> [!note]
> This guide reconstructs a static 3DGS from a single synchronized timestamp and cannot reproduce the 4DGS results shown in our work.
>
> The FreeTimeGS implementation used in the paper is not publicly available. We are evaluating open-source alternatives for a reproducible 4DGS pipeline.
