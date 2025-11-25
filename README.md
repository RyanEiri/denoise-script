# denoise-script

Classic SoX noise reduction plexed through ffmpeg — samples a short segment to profile and denoise full recordings.

This repository contains three versions of the `denoise.sh` script, each reflecting a different stage of optimization for handling large audio and video files. All scripts are written in portable Bash and rely on `ffmpeg` and `sox`.

---

## 🧱 Branch Overview

| Branch | Version | Description |
|:-------|:---------|:-------------|
| **classic** | v1.0 | The original SoX implementation using full-length WAV intermediates. Simple but not suitable for large (>4 GB) files. |
| **streamed** | v2.0 | A streamed version that eliminates temporary WAVs, using raw PCM pipes with ffmpeg. Fully multithreaded for encode/decode. |
| **parallel** | v3.0 | The most advanced version. Runs SoX per channel in parallel for higher CPU utilization and faster processing on multi-core systems. |

---

## 🚀 Usage

All versions share the same command-line interface:

```bash
./denoise.sh input.mp4 output.mp4
```

Optional parameters:

```bash
./denoise.sh input.mp4 output.mp4 [noise_start] [noise_duration] [nr_amount] [norm_db] [threads]
```

| Parameter | Default | Description |
|------------|----------|-------------|
| `noise_start` | `00:00:00` | Time offset for sampling ambient noise. |
| `noise_duration` | `00:00:00.3` | Length of sample used to build the noise profile. |
| `nr_amount` | `0.20` | Noise reduction strength (SoX `noisered` parameter). Typical range: 0.2–0.3. |
| `norm_db` | `-1` | Target level for normalization (SoX `norm` parameter). |
| `threads` | Auto (`nproc`) | ffmpeg threads for decode/encode. |

---

## 🧠 How It Works

1. ffmpeg extracts a short sample segment of the audio.
2. SoX generates a *noise profile* from that segment.
3. ffmpeg streams the full audio through SoX to apply the noise reduction and normalization.
4. The cleaned audio is re-muxed with the original video stream.

No temporary WAVs are created, so even very large recordings can be processed efficiently.

---

## ⚙️ Dependencies

- [ffmpeg](https://ffmpeg.org/)
- [SoX (Sound eXchange)](http://sox.sourceforge.net/)
- bash ≥ 4.0
- GNU coreutils

Install on Debian/Ubuntu:

```bash
sudo apt install ffmpeg sox
```

---

## 🧩 Example

```bash
./denoise.sh "2025-10-27 18-43-44.mp4" "2025-10-27 18-43-44-NR.mp4"
```

This takes a short noise sample from the start of the video, profiles it, denoises the entire audio track, and produces a cleaned output file.

---

## 🧭 Version History

| Version | Date | Summary |
|----------|------|----------|
| **v0.1** | 2024-01 | Baseline SoX version with WAV intermediates. |
| **v0.2** | 2025-10 | Streamed, multithreaded ffmpeg version — no file size limits. |
| **v0.3** | 2025-10 | Parallel per-channel SoX workers for full CPU utilization. |

---

## 🙏 Acknowledgments

The original concept of sampling ambient noise with `sox noiseprof`  
and applying it to full-length audio with `sox noisered` and `ffmpeg`  
was adapted from a discussion on [Unix & Linux Stack Exchange](https://unix.stackexchange.com/a/427343/238156)  
by user **JdeBP**. The current versions extend that method with streaming pipes,  
multithreading, and per-channel parallelization.

---

## 📄 License

This project is released under the [MIT License](LICENSE).

---

## 🧑‍💻 Author

**Ryan Eric Johnson**  
Digital Preservation Analyst · Icelandic Studies & Digital Humanities  
<https://github.com/ryanericjohnson>
