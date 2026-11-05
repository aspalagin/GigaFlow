---
library_name: mlx
license: mit
language:
  - ru
  - en
tags:
  - automatic-speech-recognition
  - mlx
  - apple-silicon
  - russian
  - gigaam
  - conformer
  - rnnt
base_model: ai-sage/GigaAM-v3
pipeline_tag: automatic-speech-recognition
---

# GigaAM v3 e2e RNNT — MLX

MLX port of [GigaAM-v3](https://github.com/salute-developers/GigaAM) RNNT variant for Apple Silicon. Higher quality than CTC, ~77x realtime on M2 Max.

## Usage

```bash
pip install git+https://github.com/aystream/gigaam-mlx.git
```

```python
from gigaam_mlx import load_model, transcribe

model, tokenizer = load_model("rnnt")  # downloads automatically
text = transcribe(model, tokenizer, "recording.wav")
```

Or via CLI:

```bash
gigaam-mlx recording.wav --model-type rnnt
```

## CTC vs RNNT

| Variant | Speed (20s chunk) | Quality | Full 18-min video |
|---|---|---|---|
| [CTC](https://huggingface.co/aystream/GigaAM-v3-e2e-ctc-mlx) | 0.06s (~330x) | Good | 21.5s |
| **RNNT (this)** | **0.26s (~77x)** | **Better** | **25.0s** |

## Links

- **Code:** [github.com/aystream/gigaam-mlx](https://github.com/aystream/gigaam-mlx)
- **CTC variant:** [aystream/GigaAM-v3-e2e-ctc-mlx](https://huggingface.co/aystream/GigaAM-v3-e2e-ctc-mlx)
- **Original:** [salute-developers/GigaAM](https://github.com/salute-developers/GigaAM) ([paper](https://arxiv.org/abs/2506.01192))
- **License:** MIT
