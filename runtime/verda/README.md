# MiniCPM-o 4.5 on Verda

This deploys the official MiniCPM-o 4.5 PyTorch full-duplex demo as a single
Verda **Continuous** GPU container. The browser UI, gateway, worker, and model
backend are all exposed through port `7860`; Nginx preserves WebSocket upgrades
needed by the real-time audio/video UI.

## First deployment

1. Push `main` and wait for the `Publish MiniCPM-o 4.5 Verda image` workflow.
   Select its immutable `ghcr.io/alimaslax/minicpm-o45-verda:<git-sha>` tag.
2. Create a new Verda **Continuous** container with one spot Blackwell / RTX
   PRO 6000 GPU, `min_replicas=1`, `max_replicas=1`, one concurrent request,
   port `7860`, and health check `/health`.
3. Attach a persistent disk at `/data`. Set `HF_TOKEN` as a Verda secret before
   first boot; it is used to download the full `openbmb/MiniCPM-o-4_5` snapshot
   into `/data/models/minicpm-o-4_5`, never into the image.
4. Set `TAILSCALE_ENABLE=1`. On first boot, approve the one-time login link in
   the replica logs (or provide `TAILSCALE_AUTHKEY` as a Verda secret). Reused
   disks retain `/data/tailscale/tailscaled.state`.

Use `https://minicpm-o45-live/` through Tailscale Serve. TLS is terminated by
Tailscale so the browser accepts microphone and camera access. Do not store Hugging
Face or Tailscale credentials in repository files, image layers, or logs.
