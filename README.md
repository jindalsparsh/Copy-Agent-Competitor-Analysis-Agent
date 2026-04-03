# Anjali Copy Agent 2.0

A production-ready, LangGraph-orchestrated content generation pipeline that reads topic rows from Google Sheets, extracts brand style from a Google Drive document, and uses Claude to generate on-brand copy, then writes the output into a Google Doc.

---

## Architecture

```
POST /run  (or APScheduler cron)
     │
     ▼
┌─────────────────────────────────────────────────────────┐
│                    LangGraph Pipeline                    │
│                                                         │
│  load_topics_from_sheet                                 │
│       │  (abort on error)                               │
│  fetch_style_doc                                        │
│       │  (abort on error)                               │
│  extract_style_text         PDF / RTF / TXT → plaintext │
│       │  (abort on error)                               │
│  infer_style_profile        Claude → raw JSON           │
│       │  (abort on error)                               │
│  validate_style_profile     Pydantic → StyleProfile     │
│       │  (abort on error)                               │
│  generate_copy              Claude (per topic row)      │
│       │  (warn on per-row error, abort on no profile)   │
│  write_to_google_doc        Docs API + Sheet status     │
│       │  (warn on error, never aborts)                  │
│  finalize_run               Structured summary log      │
└─────────────────────────────────────────────────────────┘
```

**Key design decisions:**

- **LangGraph** owns all orchestration: typed state, node routing, and abort/continue decisions.
- **Abort semantics**: any node can set `aborted=True`; the conditional edges short-circuit to `finalize_run`. Non-fatal issues become `warnings` and the run continues.
- **Claude** is called twice: once as a Style Extractor (returns strict JSON) and once as a Copy Chief (per topic row).
- **Google auth** uses service account JSON — no OAuth browser flow needed in production.
- **Scheduler** is optional (`ENABLE_SCHEDULER=true`). In containerized deployments prefer Cloud Scheduler calling `POST /run` instead.

---

## Project Structure

```
content-pipeline/
├── app/
│   ├── main.py            FastAPI app, /health, /run, scheduler
│   ├── config.py          Pydantic settings from env vars
│   ├── graph.py           LangGraph StateGraph definition
│   ├── state.py           Typed PipelineState + sub-types
│   ├── nodes/
│   │   ├── load_topics.py
│   │   ├── fetch_style_doc.py
│   │   ├── extract_style_text.py
│   │   ├── infer_style_profile.py
│   │   ├── validate_style_profile.py
│   │   ├── generate_copy.py
│   │   ├── write_to_google_doc.py
│   │   └── finalize_run.py
│   ├── prompts/
│   │   ├── style_extractor.py   Style Extractor system + user prompts
│   │   └── copy_chief.py        Copy Chief system + user prompts
│   ├── schemas/
│   │   ├── style_profile.py     StyleProfile Pydantic model
│   │   └── topic.py             TopicRow Pydantic model
│   ├── services/
│   │   ├── google_sheets.py
│   │   ├── google_drive.py
│   │   ├── google_docs.py
│   │   └── claude.py
│   └── utils/
│       ├── logging.py       structlog JSON configuration
│       └── retry.py         tenacity retry decorators
├── tests/
│   ├── test_schemas.py
│   ├── test_nodes.py
│   ├── test_graph_integration.py
│   └── test_api.py
├── Dockerfile
├── docker-compose.yml
├── pyproject.toml
├── .env.example
└── README.md
```

---

## Google Cloud Setup

### 1. Enable APIs

In the [Google Cloud Console](https://console.cloud.google.com), enable:

- Google Sheets API
- Google Drive API
- Google Docs API

### 2. Create a Service Account

```bash
# Create service account
gcloud iam service-accounts create content-pipeline \
  --display-name="Anjali Copy Agent 2.0 SA"

# Download JSON key
gcloud iam service-accounts keys create secrets/service_account.json \
  --iam-account=content-pipeline@YOUR_PROJECT.iam.gserviceaccount.com
```

### 3. Grant Access

Share the following Google Workspace resources with the service account email (`content-pipeline@YOUR_PROJECT.iam.gserviceaccount.com`):

| Resource | Permission needed |
|---|---|
| Google Sheet (source topics) | **Editor** (if updating status) or **Viewer** |
| Google Drive file (style doc) | **Viewer** |
| Google Doc (output) | **Editor** |

### 4. Get IDs

- **Sheet ID**: from the URL `https://docs.google.com/spreadsheets/d/<SHEET_ID>/edit`
- **Drive File ID**: from the URL `https://drive.google.com/file/d/<FILE_ID>/view`
- **Doc ID**: from the URL `https://docs.google.com/document/d/<DOC_ID>/edit`

---

## Local Setup

### Prerequisites

- Python 3.11+
- Anthropic API key
- Google service account JSON (see above)

### Install

```bash
cd content-pipeline

# Create virtual environment
python -m venv .venv
source .venv/bin/activate   # Windows: .venv\Scripts\activate

# Install with dev dependencies
pip install -e ".[dev]"
```

### Configure

```bash
cp .env.example .env
# Edit .env and fill in all required values
```

**Minimum required env vars:**

```
ANTHROPIC_API_KEY=sk-ant-...
GOOGLE_APPLICATION_CREDENTIALS=./secrets/service_account.json
GOOGLE_SHEET_ID=...
GOOGLE_DRIVE_FILE_ID=...
GOOGLE_DOC_ID=...
```

### Google Sheet Format

The pipeline expects the sheet to have a header row with these columns (case-insensitive):

| topic | audience | objective | priority | status |
|---|---|---|---|---|
| AI Trends 2025 | CTOs | Drive newsletter signups | HIGH | READY |
| Cloud Security | CISOs | Educate on zero-trust | MEDIUM | DRAFT |

Only rows with `status == READY` (configurable via `PROCESS_STATUS_FILTER`) are processed.

### Run Locally

```bash
# Start the API server
uvicorn app.main:app --reload --port 8000

# Trigger the pipeline
curl -X POST http://localhost:8000/run

# Check health
curl http://localhost:8000/health
```

### Run Tests

```bash
pytest tests/ -v
```

---

## Docker Usage

### Build and run

```bash
# Copy your service account key
mkdir -p secrets
cp /path/to/your/service_account.json secrets/service_account.json

# Copy and configure env
cp .env.example .env
# Edit .env

# Build and start
docker compose up --build

# Trigger a run
curl -X POST http://localhost:8000/run
```

### Environment variables for Docker

All configuration is passed as environment variables. See `.env.example` for the full list. Docker Compose reads from your `.env` file automatically.

---

## Scheduling

### Option A: Internal APScheduler (simple deployments)

Set `ENABLE_SCHEDULER=true` and `SCHEDULE_CRON="0 8 * * 1-5"` (weekdays at 8 AM UTC).

The scheduler starts with the app. Use only with a single replica to avoid duplicate runs.

### Option B: Cloud Scheduler + HTTP trigger (recommended for production)

1. Deploy the container (Cloud Run, GKE, ECS, etc.)
2. Create a Cloud Scheduler job:

```bash
gcloud scheduler jobs create http content-pipeline-job \
  --schedule="0 8 * * 1-5" \
  --uri="https://YOUR_SERVICE_URL/run" \
  --http-method=POST \
  --time-zone="UTC"
```

Keep `ENABLE_SCHEDULER=false` in the container — Cloud Scheduler owns the trigger.

---

## Deployment

### Cloud Run (recommended)

```bash
# Build and push
docker build -t gcr.io/YOUR_PROJECT/content-pipeline:latest .
docker push gcr.io/YOUR_PROJECT/content-pipeline:latest

# Deploy
gcloud run deploy content-pipeline \
  --image gcr.io/YOUR_PROJECT/content-pipeline:latest \
  --region us-central1 \
  --platform managed \
  --set-env-vars ANTHROPIC_API_KEY=... \
  --set-secrets GOOGLE_APPLICATION_CREDENTIALS=service-account-key:latest \
  --timeout 300 \
  --no-allow-unauthenticated
```

### Idempotency

The pipeline is safe to re-run because:
- It re-reads the sheet on every run; only rows with `status=READY` are processed.
- After successful processing, rows are updated to `DONE` (if `UPDATE_SHEET_STATUS=true`).
- If a run fails mid-way, rows remain `READY` and will be retried on the next run.
- The Google Doc gets a new section per run with the run ID and timestamp, so duplicate runs are visible but not destructive.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `google.auth.exceptions.DefaultCredentialsError` | Wrong path to service account JSON | Check `GOOGLE_APPLICATION_CREDENTIALS` |
| `HttpError 403` | Service account lacks permission | Share the resource with the SA email |
| `HttpError 404` | Wrong Sheet/Drive/Doc ID | Verify the IDs in `.env` |
| `anthropic.AuthenticationError` | Invalid API key | Check `ANTHROPIC_API_KEY` |
| `validate_style_profile: JSON parse error` | Claude returned malformed JSON | Check the style doc — very short docs can confuse the model |
| Empty `eligible_topics` | No rows with the right status | Ensure rows have `status=READY` (or change `PROCESS_STATUS_FILTER`) |
| Scheduler fires but no rows processed | Style doc or sheet issue | Check logs — each node emits structured JSON logs |

### Logs

All logs are JSON-structured (structlog). In production, ship them to your log aggregator. Locally:

```bash
uvicorn app.main:app 2>&1 | python -m json.tool
```

Or with jq:

```bash
uvicorn app.main:app 2>&1 | jq .
```
