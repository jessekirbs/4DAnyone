# CUDA 12.8 devel image matches the torch 2.8 wheels pinned in requirements.txt
FROM nvidia/cuda:12.8.1-cudnn-devel-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    UV_LINK_MODE=copy

RUN apt-get update && apt-get install -y --no-install-recommends \
      git git-lfs curl ca-certificates sudo build-essential ninja-build \
      ffmpeg libgl1 libglib2.0-0 libsm6 libxext6 libxrender1 \
      openssh-client unzip less \
    && rm -rf /var/lib/apt/lists/*

# Non-root user (uid 1000 may already exist in the base image; handle both)
ARG USERNAME=vscode
RUN (id -u 1000 >/dev/null 2>&1 && usermod -l ${USERNAME} -d /home/${USERNAME} -m $(id -nu 1000) && groupmod -n ${USERNAME} $(id -gn 1000)) \
    || useradd -m -s /bin/bash -u 1000 ${USERNAME}; \
    echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USERNAME} && chmod 0440 /etc/sudoers.d/${USERNAME}

USER ${USERNAME}
ENV PATH="/home/${USERNAME}/.local/bin:${PATH}"

# uv provides Python 3.11 and the virtualenv without needing conda
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
