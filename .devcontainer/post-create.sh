#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

git config --global --add safe.directory "$PWD"
git submodule update --init third_party/GVHMR

# .venv lives in the bind-mounted workspace, so it survives rebuilds while the
# uv-managed interpreter it links to does not; recreate it each time.
uv venv --clear --python 3.11 .venv
uv pip install --python .venv/bin/python -r requirements.txt -r requirements-gui.txt

python_bin=.venv/bin/python

# Hugging Face serves weights from Xet storage behind rotating IPs that the
# outbound firewall can't allowlist, so fetch them while the network is still
# open. Files already in models/ are skipped.
"$python_bin" scripts/download_model.py \
  || echo "WARN: model download failed; rerun scripts/download_model.py with ENABLE_FIREWALL=0"
"$python_bin" scripts/download_example.py \
  || echo "WARN: example download failed; rerun scripts/download_example.py with ENABLE_FIREWALL=0"

echo
"$python_bin" - <<'PY'
import torch
print("torch", torch.__version__, "| CUDA available:", torch.cuda.is_available())
PY
cat <<'MSG'

Setup done. Next steps:
  python scripts/download_smplx.py   # needs SMPL-X license acceptance
  python inference.py --video_path <video> --output_dir <dir> --views_per_layer 6
  python app.py --server_port 7860   # GUI
  claude                             # start Claude Code
MSG
