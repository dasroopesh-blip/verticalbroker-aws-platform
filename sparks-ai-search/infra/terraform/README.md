# SPARKS AI Search — Terraform IaC

Infrastructure-as-Code for the **production-ready** Option 1 (RAG) and Option 2 (Agentic)
AI search. Written to be **beginner-friendly**: heavily commented, small modules, one
environment folder you actually run from.

> ⚠️ **NO SPEND UNTIL FED APPROVAL.** Do not `terraform apply` until the FED Lead approves
> AI-tool use in Dev. `terraform validate` / `plan` cost nothing and are safe to run.

## Layout

```
infra/terraform/
├── README.md                  ← you are here
├── envs/
│   └── dev/                   ← the folder you run terraform from (Dev first)
│       ├── main.tf            ← wires the modules together
│       ├── variables.tf       ← inputs you set per environment
│       ├── outputs.tf         ← handy outputs (API URL, bucket, etc.)
│       ├── providers.tf       ← AWS provider + remote state backend
│       └── dev.tfvars.example ← copy to dev.tfvars and fill in
└── modules/                   ← reusable building blocks (one concern each)
    ├── ai_search_content/             ← S3 bucket for the curated search content (+KMS, versioning)
    ├── vector_index/          ← OpenSearch Serverless vector collection
    ├── bedrock_rag/           ← Bedrock Knowledge Base over the search content (Option 1)
    ├── ask_api/               ← API Gateway + Ask Lambda (/ask, /health)
    ├── agent/                 ← Bedrock Agent + tool Lambdas (Option 2, optional)
    └── observability/         ← CloudWatch dashboard, alarms, AWS Budget
```

## How to use (once approved)

```bash
cd envs/dev
cp dev.tfvars.example dev.tfvars     # fill in region, VPC, model IDs, etc.
terraform init                       # sets up providers + remote state
terraform validate                   # free: checks config
terraform plan  -var-file=dev.tfvars # free: shows what WOULD be created
terraform apply -var-file=dev.tfvars # ← ONLY after FED approval (incurs cost)
```

## Toggles
- `enable_agent = false` → deploys **Option 1 (RAG)** only.
- `enable_agent = true`  → also deploys **Option 2 (Agentic)** tools + Bedrock Agent.

## What this does NOT touch
Nothing in the existing SPARKS pipeline (the two Lambdas, `SearchQueue.fifo`, the
`sparks.open_search_json` outbox, the `json_*_rec()` builders, or the current OpenSearch
`sparks-stage` domain and its UI). This stack only **reads** the outbox and adds a
separate AI layer.
