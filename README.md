Kie.ai Midjourney API validation: sref/cref experiments

Purpose
- Local-run experiment harness to validate Kie.ai/Bylo Midjourney API image generation and confirm application of style (sref) and character (cref/omni) references.
- Uses POSIX shell (sh), curl, and jq. No SDKs or secrets are committed.

Safety notes
- Do not commit API keys or secrets to this repo.
- Be mindful of provider ToS and asset retention windows (some providers retain for ~15 days). Mirror assets you want to keep.
- Endpoints and JSON paths are configurable per experiment; update them to match your provider’s documentation.

Requirements
- sh/bash
- curl
- jq

Environment
- export KIE_API_KEY=YOUR_KEY
- export KIE_BASE_URL=https://your-kie-base-url
- optional: export KIE_AUTH_HEADER=Authorization (or X-API-KEY)
- optional: export KIE_AUTH_SCHEME=Bearer (or empty to send only the key value)
- optional: export VERBOSE=1 to capture HTTP status codes and response headers to experiments/N/http.log for each run. Authorization header values are redacted in logs.

How to run
1) Run a single experiment by pointing at its input.json:
   - sh scripts/run_experiments.sh experiments/1/input.json
2) Outputs:
   - Images saved under experiments/N/outputs/ as 0.png, 1.png, ...
   - Status saved to experiments/N/status.json
   - Initial submission response saved to experiments/N/initial_response.json
3) Repeat for experiments/2–4.
4) For experiment 5 (transform/upscale):
   - First run experiment 1. The script will write experiments/1/task_id.txt automatically.
   - experiments/5/input.json contains a placeholder taskId. The run script will automatically inject experiments/1/task_id.txt if present. Alternatively, manually edit the taskId field before running.

Config JSON schema
{
  "endpoint": "/<path>",
  "method": "POST",
  "payload": { ... },
  "statusEndpoint": "/<path>",
  "taskIdJsonPath": ".data.taskId",
  "statusJsonPath": ".data.status",
  "successFlagJsonPath": ".data.successFlag",
  "resultUrlsJsonPath": ".data.resultUrls[]",
  "pollIntervalSec": 30,
  "maxPolls": 40
}

Notes and mapping
- Endpoints are placeholders (e.g., "/mj/generate-mj-image", "/mj/get-mj-task-details", "/mj/upscale"). Update as needed.
- The JSON paths are jq expressions. If your provider returns different shapes, edit these to match (use the saved initial_response.json and status.json to discover actual fields).
- Common fields observed in similar APIs: data.taskId, data.status, data.successFlag, data.resultUrls[].

Experiments
- experiments/1: mj_txt2img baseline (v7 relaxed, ar 1:1) with a longer English prompt.
- experiments/2: mj_style_reference with 2 style fileUrls. Uses raw GitHub URLs to images in this repo: cat.png and gradient.png. Replace with your own if desired.
- experiments/3: mj_omni_reference (character/omni) with 2 fileUrls and ow: 500.
- experiments/4: mj_txt2img with prompt pass-through flags combined: --sref ... --sw 0.6 --cref ... --cw 0.85 --seed 123456.
- experiments/5: Transform (upscale). Reads experiments/1/task_id.txt if the placeholder is not replaced.

Troubleshooting
- 401 Unauthorized: verify KIE_API_KEY, header name (KIE_AUTH_HEADER), and scheme (KIE_AUTH_SCHEME). Some providers expect X-API-KEY with no scheme.
- 402 Payment Required: ensure your account has credits/quota.
- 429 Too Many Requests: the script retries with exponential backoff; increase pollIntervalSec or try again later.
- Different JSON paths: edit the *JsonPath fields in the experiment’s input.json; the harness is path-driven.

Current API behavior notes
- Provide Midjourney version as a numeric value (e.g., 7), not a string.
- Speed parameter must be lowercase where applicable (e.g., "relaxed", "fast", "turbo"). Omni reference does not require speed.

Sample reference assets
- Public/raw URLs assumed for experiments 2 and 3:
  - https://raw.githubusercontent.com/HautechAI/test-mj-api/main/cat.png
  - https://raw.githubusercontent.com/HautechAI/test-mj-api/main/gradient.png

Pass-through prompt tests (experiments 6–9)
- experiments/6: mj_txt2img with the same base prompt only (no flags). Speed fast, ar 3:4, v7.
- experiments/7: mj_txt2img with pass-through cref only (cat.png) using integer cw=85 and seed 123456.
- experiments/8: mj_txt2img with pass-through sref only (gradient.png) using integer sw=60 and seed 123456.
- experiments/9: mj_txt2img with both cref (cat.png, cw=85) and sref (gradient.png, sw=60) plus seed 123456.

Known quirks observed so far
- Some providers report cref incompatible with v7; these tests still capture pass-through behavior and status.
- cw/sw are expected as integers on some endpoints; included here as 85 and 60, respectively.
- Speed is required by the API for pass-through routes; these use speed="fast".

Pass-through prompt tests (experiments 10–13)
- Goal: Use a single clean base prompt to test pass-through behavior for sref/cref with Midjourney v7. This captures how providers handle flags and seeds when embedded in the prompt string itself.
- Base prompt (same for 10–13):
  - "Cat is sitting on the beach and watching sunset. Front view 45 degrees."
- Common settings across 10–13:
  - taskType: mj_txt2img
  - version: 7 (numeric)
  - speed: "fast"
  - aspectRatio: "3:4"
  - stylization: 300
  - weirdness: 150
  - seed: 123456 (when using pass-through flags)
  - endpoint: "/api/v1/mj/generate"
  - statusEndpoint: "/api/v1/mj/record-info?taskId={taskId}"
  - JSON paths as in earlier experiments: taskId .data.taskId, status .data.successFlag, successFlag .data.successFlag, resultUrls .data.resultInfoJson.resultUrls[].resultUrl
- Image URLs:
  - cref (character): https://raw.githubusercontent.com/HautechAI/test-mj-api/main/cat.png
  - sref (style): https://raw.githubusercontent.com/HautechAI/test-mj-api/main/gradient.png
- cw/sw must be integers on some endpoints; we use cw=85 and sw=60.
- Some providers report cref incompatible with v7; we still include it to capture behavior.

- experiments/10: pure prompt only (no flags). Seed not included in prompt. Speed fast, ar 3:4, v7.
- experiments/11: base prompt + " --cref <cat_url> --cw 85 --seed 123456 --v 7 --ar 3:4".
- experiments/12: base prompt + " --sref <gradient_url> --sw 60 --seed 123456 --v 7 --ar 3:4".
- experiments/13: base prompt + " --sref <gradient_url> --sw 60 --cref <cat_url> --cw 85 --seed 123456 --v 7 --ar 3:4".
