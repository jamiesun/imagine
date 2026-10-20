# Qwen3-TTS adapter (`tts_http`)

`imagine` does not speak Qwen's HTTP API and does not ship weights. This
process adapts a local Qwen3-TTS runtime to **imagine.tts_http.v1**.

```bash
python3 integrations/qwen3-tts/server.py --mock
```

Defaults to `127.0.0.1:8712`. `--mock` returns a tiny valid WAV and does not
import `qwen_tts`, so CI never downloads a model.

```toml
[models."qwen3-tts"]
backend = "tts_http"
api_model = "qwen3-tts"

[[models."qwen3-tts".endpoints]]
base_url = "http://127.0.0.1:8712/generate"
auth = "none"
```

```bash
imagine generate -m qwen3-tts -p "hello" -o hello.wav
imagine voices -m qwen3-tts
```

## Wire

| Call | Meaning |
| --- | --- |
| `GET /capabilities` | Narrows the protocol ceiling before a generate POST |
| `GET /voices` | Voice names |
| `POST /generate` | JSON in. JSON `audio` (base64) or, only when capabilities say so, NDJSON chunks |

`/capabilities` reports `"streaming": false` unless the process was started with
`--stream-chunks`. Qwen's official `non_streaming_mode=false` finishes the clip
and then slices the body. That is not incremental audio, and this server will
not advertise it as streaming. `imagine` rejects a strict `--stream` before the
generate POST when the server says streaming is false.

Modes on a real (non-mock) process map to `generate_custom_voice`,
`generate_voice_design`, and `generate_voice_clone`. Those imports happen only
when the server is started with `--real`. The default is mock and does not
download weights.
