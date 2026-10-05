# Strata on the homelab (`homelab/main`)

Fork of [Niko1221/Strata](https://github.com/Niko1221/Strata) for running Qwen3.8-Flash-Next on
**adell** (RTX 3090 24 GB, Ryzen 9 5950X, 128 GB DDR4, Fedora 43) as a candidate replacement for the
llama-server `qwen3.8:27b` backend in the homelab cluster (`clusters/homelab/llama-server/` in the
homelab repo). Upstream code is untouched; everything here lives in `homelab/`.

Branch convention: `main` tracks upstream, `homelab/main` = upstream + this directory. Rebase onto
`upstream/main` to update.

## What's here

| File | Purpose |
| --- | --- |
| `build-in-container.sh` | Builds the engine and `strata-vision` in a CUDA 13.0 Ubuntu container and stamps `engine/BUILD.json` so setup never compiles on the host |
| `strata-iq3_xxs.json` | The run config as tested on adell (paths under `/srv/strata`), `vision.max_tokens` raised to 4096 |

## Install on adell (as done 2026-10-04)

Data lives on a dedicated LV because `/` is ~90% full:
`vg1/strata` (200G, SATA SSD), xfs, mounted at `/srv/strata`. **Not in fstab** - remount after a reboot:
`sudo mount /dev/vg1/strata /srv/strata`.

```sh
cd /srv/strata && git clone -b homelab/main https://github.com/jhjaggars/Strata && cd Strata
# 1. first setup run: creates .venv and fetches llama.cpp, then fails on the host compile (expected)
./setup.sh --yes --family qwen --model IQ3_XXS --context 131072 --vision no \
  --data-dir /srv/strata/data --no-start --no-browser
# 2. build in a container instead
homelab/build-in-container.sh
# 3. setup again: skips the compile, downloads ~76 GB + MTP layer + vision encoder, writes the run files
./setup.sh --setup --yes --family qwen --model IQ3_XXS --context 131072 --vision gpu --vision-tokens 4096 \
  --data-dir /srv/strata/data --no-start --no-browser
# 4. add the sampling block (without it the server decodes greedy) - or copy homelab/strata-iq3_xxs.json
```

Re-run `homelab/build-in-container.sh` after every upstream update: `BUILD.json` records source hashes,
and a stale hash makes setup try (and fail) to recompile on the host.

## Run

The GPU is shared with llama-server, which must be held at 0 first (Flux reverts a bare `kubectl scale`):

```sh
kubectl annotate deploy/llama-server -n open-webui kustomize.toolkit.fluxcd.io/reconcile=disabled --overwrite
kubectl scale deploy/llama-server -n open-webui --replicas=0
ssh adell 'sudo systemd-run --unit=strata-trial --uid=jhjaggars --gid=jhjaggars -p LimitMEMLOCK=infinity \
  -p WorkingDirectory=/srv/strata/Strata /bin/sh /srv/strata/Strata/run-iq3_xxs.sh'
```

`LimitMEMLOCK=infinity` is required: Strata pins ~40 GiB of experts and the default memlock limit is 8 MiB.
Ready in ~2-2.5 min (experts load at ~0.5 GiB/s off the SATA SSD). Serves `127.0.0.1:8080` only; reach it
with `ssh -L 18080:127.0.0.1:8080 adell`. Undo: `systemctl stop strata-trial`, scale llama-server to 1,
remove the annotation.

## Measured 2026-10-04 (IQ3_XXS, 128K context, KV streaming, 1 slot)

Against llama-server `qwen3.8:27b` UD-IQ4_XS @196608 on the same GPU:

| | llama-server 27B | Strata |
| --- | --- | --- |
| homelab agentic eval, 80 paired runs (medium effort) | 80/80 | 75/80 - all 5 fails are `harness_probed` runs (35/80 probed the fake kubectl; 27B: 0/80); clean 45/45 |
| reasoning chars / task (geo-mean ratio) | 1.00 | 1.04 (n.s.) |
| wall clock / task (geo-mean ratio) | 1.00 | **0.67** (95% CI 0.58-0.77) |
| cold prefill | ~500 tok/s at 130K | 1,750-2,270 tok/s up to 114K (**52 s TTFT at 114K**) |
| decode | - | ~97 tok/s short, 65 at 114K depth |
| paperless OCR, 25 docs, blind Sonnet judge | 85.3, 444 s | **90.7 @4096 img tokens, ~225 s**; 87.0 @1024, 141 s |

**Never serve OCR at the default 1,024 image tokens**: a full 1700x2200 page is downscaled to ~108 dpi, and
on a dense waiver it invented contract clauses (score 30 vs 98 at 4096). Vision on costs ~1.1K experts of
VRAM cache (10,468 -> 9,385).

Production load (7 days of llama-server metrics) is ~1.8% busy and single-request 96% of the time, so the
1-slot default is fine; an M/G/1 estimate puts the busiest-hour mean added wait at ~3.5 s.

Raw results are in the homelab repo: `evals/homelab/results/strata_iq3xxs_medium.json`,
`evals/ocr/strata_*`.

## Gotchas

- No server-side default reasoning effort: requests without one think at **high**, which spent 4,000
  tokens on a one-line question. Clients/gateway must send `reasoning_effort` (or
  `chat_template_kwargs.enable_thinking`).
- No `sampling` block in the config = greedy decoding.
- `/metrics` is the web UI's JSON, not Prometheus format.
- `response_format: json_schema` is prompted + validated (502 on a miss), not grammar-constrained.
- The stock chat template is used; the homelab llama-server's patched agentic template does not apply.
- With the default adaptive expert cache, seeded sampling is not reproducible run to run.

## Not yet tested

- `--conversation-cache-mib 8192 --conversation-cache-slots 4` in `args`: parks alternating
  conversations in RAM so two agents taking turns don't each re-read their history (default caches one).
- Real gateway traffic (point the `qwen3.8` route at Strata for a day).
- Running in-cluster (needs an image, a `/metrics` adapter, and a local volume for the 29 GB SSD table).
