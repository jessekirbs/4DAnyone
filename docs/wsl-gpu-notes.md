# WSL2 + RTX 4090 inference notes

Working notes from getting `inference.py` to run in the dev container on WSL2.
Last updated 2026-10-23. **Status: not working yet.** The pose-step crash is fixed, but the
generation step doesn't fit in the VRAM that WSL leaves free.

## Setup

| | |
|---|---|
| Host | Windows + WSL2, kernel `6.18.33.1-microsoft-standard-WSL2` |
| GPU | RTX 4090, 24 GB; driver 617.14 |
| Free VRAM in WSL | **22.45 GiB** of 23.99 GiB (Windows keeps about 1.5 GiB for the desktop) |
| PyTorch | 2.8.0+cu128, cuDNN 9.10.2 |
| Windows setting | NVIDIA Control Panel → Manage 3D settings → Global → "CUDA - Sysmem Fallback Policy" = **Prefer No Sysmem Fallback** (WSL restarted with `wsl --shutdown` afterwards) |

Test command used throughout:

```bash
.venv/bin/python inference.py data/source/pexels/7017803-hd_1080_1920_30fps.mp4 \
  --output_dir outputs/testN --views_per_layer 6
```

## Problem 1: `CUDA driver error: device not ready` at pose encoding (fixed)

**Symptom:** GVHMR preprocessing and framing finish (about 2 min). Then the run crashes in the
pose encoder's first `F.conv3d` (`fdanyone/vendor/diffsynth/models/wan_video_pose_encoder.py:81`)
with `RuntimeError: CUDA driver error: device not ready`.

**Cause:** PyTorch's expandable-segments allocator doesn't work with the WSL GPU driver.
`inference.py:68` turns it on automatically for 24 GB-class GPUs
(`configure_inference_cuda_allocator(use_expandable_segments=low_memory)`).

**Evidence:** pose encoder tested on its own at the real batch size of 6
(`POSE_ENCODER_BATCH_LIMIT = 6`, `fdanyone/model/conditioning.py:32`):

| `PYTORCH_CUDA_ALLOC_CONF` | Variant | Result |
|---|---|---|
| `expandable_segments:True` | default | FAIL after 1.1 s, 13.7 GiB peak |
| `expandable_segments:True` | `CUDA_LAUNCH_BLOCKING=1` | FAIL after 1.3 s, no more detail |
| `expandable_segments:True` | cuDNN disabled | FAIL after 0.5 s at only 7.5 GiB reserved, so it isn't cuDNN or memory size |
| `expandable_segments:True` | batch 1 | ok |
| `expandable_segments:False` | default | **ok in 4.3 s**, 20.4 GiB peak, 24.2 GiB reserved |

(An earlier `expandable_segments:False` attempt hung for 4 to 5 minutes and was killed. This
couldn't be reproduced later the same day, and the cause is unknown.)

**Fix:** set the variable before running. `fdanyone/device.py:96` only adds
`expandable_segments:True` when the key isn't already set, so no code change is needed:

```bash
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:False
```

## Problem 2: generation stalls (open)

With the fix above (`outputs/test3`, log `outputs/test3-run.log`), the run passes the pose step.
All six skeleton conditionings loaded by 09:23:48. It then sat at
`Generate 6 target views: 0/4` for **over 8 hours** with VRAM full (24,034 MiB) and 100% GPU
utilisation, and was killed. For comparison, the project's 4090 benchmark
(`docs/inference_performance.md`) does generation in about 2.7 min at a 22.18 GB peak, measured on
native Linux.

**Likely cause:** generation needs more VRAM than the 22.45 GiB available under WSL, and the
extra spills into system RAM, where it runs extremely slowly. The Windows sysmem fallback setting
doesn't prevent this under WSL.

**Untested contributing factor:** the comment at `inference.py:64` says expandable segments are
used to protect a reusable 5 to 6 GiB DiT FFN allocation from fragmentation. With them turned off,
fragmentation may push peak memory higher.

## Lessons for future sessions

- **The "30 GB test" doesn't tell you whether the fallback setting works.** It allocates 30 × 1 GiB
  with `torch.empty` on the 24 GB card. It always succeeded, both before and after the Windows
  setting was applied. `torch.empty` never writes to the memory, and WSL can hand out the address
  space without real VRAM behind it. Test with real workloads instead.
- To check WSL actually restarted, run `uptime -s`.
- The pose-encoder test script (`pose_repro.py`) loads the pose encoder and encodes a random
  `(batch, 3, 124, 1280, 704)` bf16 tensor via `fdanyone.model.conditioning._encode_pose_batch`.
  Run it as `python pose_repro.py <batch> main|thread`, and set `NO_CUDNN=1` to disable cuDNN. It
  lived in a session scratchpad, so recreate it if needed.

## Options to continue

1. **Native Linux** on this machine: all 24 GB free, matching the benchmark setup. Most likely to work.
2. **Free Windows VRAM:** close GPU-heavy apps and browsers, or drive the display from integrated
   graphics. This might recover a few hundred MB to about 1 GB, which may not be enough.
3. **A GPU with more than 24 GB**, local or cloud.
4. **Code changes for WSL**, such as a smaller pose batch. Not recommended: the batch of 6 is fixed on
   purpose to match the released model's results, and it doesn't address the generation-step memory.

## Leftovers

`outputs/test`, `outputs/test2` and `outputs/test3` (with their `*-run.log` files) hold only partial
GVHMR intermediates and can be deleted.
