#!/bin/sh
# Build the Strata engine and the strata-vision helper inside a CUDA 13.0 Ubuntu
# container, then stamp engine/BUILD.json so setup.py treats them as a local
# build and never tries to compile on the host.
#
# Why: there are no Linux ready-made engines in any release (Windows only), and
# on Fedora 43 (glibc 2.42) every host CUDA toolkit (12.8, 12.9, 13.1) fails to
# compile anything that includes <cmath>: glibc's new rsqrt/rsqrtf declarations
# clash with CUDA's math_functions.h. Ubuntu 24.04 (glibc 2.39) has no clash.
#
# The binaries link libcudart/libcublas dynamically and run on the host against
# /usr/local/cuda-13.1/lib64 (same .so.13 major). GGML_CUDA_NCCL=OFF because
# the host has no libnccl and this is a single-GPU box.
#
# Run from the checkout root on the GPU host, after setup.py has created .venv
# and third_party/llama.cpp (a first ./setup.sh run gets that far before it
# fails on the compile):
#   homelab/build-in-container.sh            # sm_86 (RTX 3090)
#   CUDA_ARCH=89 homelab/build-in-container.sh
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
ARCH=${CUDA_ARCH:-86}
IMAGE=${BUILD_IMAGE:-docker.io/nvidia/cuda:13.0.0-devel-ubuntu24.04}
# Keep podman's storage off the root filesystem (adell's / is ~90% full).
STORE=${PODMAN_STORE:-$(dirname "$ROOT")/podman}
HOST_CUDA=${HOST_CUDA:-/usr/local/cuda-13.1}

mkdir -p "$STORE/root" "$STORE/run"
podman --root "$STORE/root" --runroot "$STORE/run" run --rm \
  --security-opt label=disable -v "$ROOT:$ROOT" "$IMAGE" bash -c "
set -e
apt-get update -qq && apt-get install -y -qq --no-install-recommends cmake ninja-build build-essential git >/dev/null
cmake -G Ninja -S $ROOT -B $ROOT/build-ctr -DCMAKE_BUILD_TYPE=Release \
  -DSTRATA_ENABLE_CUDA=ON -DSTRATA_BUILD_TESTS=OFF -DCMAKE_CUDA_ARCHITECTURES=$ARCH \
  -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc -DSTRATA_GGML_DIR=$ROOT/third_party/llama.cpp
cmake --build $ROOT/build-ctr --target strata -j \$(nproc)
cmake -G Ninja -S $ROOT/tools/vision -B $ROOT/build-vision-ctr -DCMAKE_BUILD_TYPE=Release \
  -DLLAMA_DIR=$ROOT/third_party/llama.cpp -DSTRATA_VISION_CUDA=ON -DGGML_CUDA_NCCL=OFF \
  -DCMAKE_CUDA_ARCHITECTURES=$ARCH -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc
cmake --build $ROOT/build-vision-ctr --target strata-vision -j \$(nproc)
"

mkdir -p "$ROOT/engine"
cp "$ROOT/build-ctr/strata" "$ROOT/engine/strata"
cp "$ROOT/build-vision-ctr/bin/strata-vision" "$ROOT/engine/strata-vision"

for b in strata strata-vision; do
  if LD_LIBRARY_PATH="$HOST_CUDA/lib64" ldd "$ROOT/engine/$b" | grep -q "not found"; then
    echo "engine/$b has unresolved libraries:" >&2
    LD_LIBRARY_PATH="$HOST_CUDA/lib64" ldd "$ROOT/engine/$b" | grep "not found" >&2
    exit 1
  fi
done

# The stamp build_engine() would have written. src/vision_src must be the
# current source hashes, or setup.py decides the source changed and recompiles
# (on the host, where it fails).
cd "$ROOT"
.venv/bin/python - "$ARCH" "$HOST_CUDA" <<'EOF'
import json, sys
import setup as s
arch, cuda = int(sys.argv[1]), sys.argv[2]
meta = {"source": "local", "version": s.source_version(), "archs": [arch], "vision": "gpu",
        "cuda_dirs": [f"{cuda}/bin", f"{cuda}/lib64"],
        "src": s.source_hash(s.ENGINE_SOURCES), "vision_src": s.source_hash(s.VISION_SOURCES)}
floor = s.cpu_floor(s.cpu_info()[1])
if floor:
    meta["isa_floor"] = floor
(s.engine_dir(13) / "BUILD.json").write_text(json.dumps(meta, indent=1))
print("stamped", s.engine_dir(13) / "BUILD.json", meta)
EOF
