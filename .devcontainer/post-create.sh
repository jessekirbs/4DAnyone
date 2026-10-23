#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Fix ownership of volume mounts (created as root by Docker)
sudo chown -R "$(id -u):$(id -g)" ~/.cache ~/.claude 2>/dev/null || true

git config --global --add safe.directory "$PWD"
git submodule update --init third_party/GVHMR

uv venv --python 3.11 .venv
uv pip install --python .venv/bin/python -r requirements.txt -r requirements-gui.txt

echo
python_bin=.venv/bin/python
"$python_bin" - <<'PY'
import torch
print("torch", torch.__version__, "| CUDA available:", torch.cuda.is_available())
PY
cat <<'MSG'

Setup done. Next steps:
  python scripts/download_smplx.py   # needs SMPL-X license acceptance
  python scripts/download_model.py
  python inference.py --video_path <video> --output_dir <dir> --views_per_layer 6
  python app.py --server_port 7860   # GUI
  claude                             # start Claude Code
MSG
