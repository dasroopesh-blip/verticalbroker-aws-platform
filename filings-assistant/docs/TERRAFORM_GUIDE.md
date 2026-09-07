# Terraform guide (learn from scratch)

This project's infrastructure is defined with **Terraform**. If you're new to it,
this walkthrough explains the concepts *using the files in this repo* so you
learn by reading real, working code.

## The mental model

Terraform is **declarative**: you describe the infrastructure you *want*, and
Terraform figures out the API calls to create/update/delete resources to match.

```
You write .tf files  ──►  terraform plan  ──►  terraform apply  ──►  AWS resources
   (desired state)         (preview diff)        (make it real)        (actual state)
```

Terraform records what it created in a **state file** (`terraform.tfstate`). On
the next `plan`, it compares your files to state to compute the minimal change.

## The building blocks (with examples from this repo)

### 1. Providers — *what cloud am I talking to?*
`terraform/versions.tf` pins the AWS provider; `terraform/main.tf` configures it:
```hcl
provider "aws" {
  region = var.aws_region
  default_tags { tags = local.common_tags }  # tag every resource automatically
}
```

### 2. Resources — *the things you create*
A resource is one piece of infrastructure. Example (`modules/queue/main.tf`):
```hcl
resource "aws_sqs_queue" "ingest" {
  name = "${var.name_prefix}-ingest"
  ...
}
```
`aws_sqs_queue` is the type; `ingest` is your local name; you reference it
elsewhere as `aws_sqs_queue.ingest.arn`.

### 3. Variables — *the inputs*
Declared in `variables.tf`, given values in `environments/dev.tfvars`:
```hcl
variable "db_instance_class" {
  description = "RDS Postgres instance class."
  type        = string
  default     = "db.t3.micro"
}
```
Every variable here has a `type` and `description` (a good habit + our convention).

### 4. Outputs — *the results*
`outputs.tf` exposes values after apply (e.g. the OpenSearch endpoint) so you can
feed them into app config.

### 5. Modules — *reusable groupings*
A module is a folder of `.tf` files. The root `main.tf` **calls** child modules
and wires them together:
```hcl
module "search" {
  source     = "./modules/search"
  vpc_id     = module.networking.vpc_id   # output of one module → input of another
  subnet_ids = module.networking.private_subnet_ids
}
```
Terraform reads these references to build a **dependency graph** and creates
things in the right order automatically (networking before search, etc.).

### 6. Data sources — *look up existing info*
Read-only lookups, e.g. which AZs exist (`modules/networking/main.tf`):
```hcl
data "aws_availability_zones" "available" { state = "available" }
```

## This repo's module map

```
terraform/
├── versions.tf      # provider + version pins (+ optional remote state)
├── variables.tf     # all inputs
├── main.tf          # wires modules together (the "main()")
├── outputs.tf       # endpoints/URLs to use in app config
├── environments/
│   └── dev.tfvars.example   # cheap dev values
└── modules/
    ├── networking/  # VPC + private subnets + Lambda security group
    ├── security/    # KMS key + IAM role/policies (least-privilege Bedrock)
    ├── queue/       # SQS ingest queue + dead-letter queue
    ├── database/    # RDS Postgres + Secrets Manager password
    ├── search/      # Amazon OpenSearch domain
    ├── compute/     # worker Lambda + SQS trigger
    └── monitoring/  # AWS Budgets cost alarm + SNS
```

## The workflow

```bash
# One-time per copy of the repo:
cp terraform/environments/dev.tfvars.example terraform/environments/dev.tfvars
# edit dev.tfvars — at minimum set budget_alert_email

./scripts/build-lambda.sh          # produce worker.zip the compute module needs

make tf-init      # download providers, prepare the working dir
make tf-plan      # PREVIEW: shows +create / ~change / -destroy. Read this!
make tf-apply     # execute the plan (asks for confirmation)

# ... use the stack ...

make tf-destroy   # ⚠️ delete everything so idle infra stops billing
```

## Concepts worth knowing early

- **`terraform fmt`** — auto-formats `.tf` files (CI checks this).
- **`terraform validate`** — checks syntax/refs without touching AWS.
- **Idempotency** — running `apply` twice with no file changes does nothing.
- **State is sensitive** — it can contain secrets; never commit `*.tfstate`
  (it's gitignored). For teams, use the remote S3 backend (commented in
  `versions.tf`).
- **`lifecycle { ignore_changes = [...] }`** — used on the Lambda so a rebuilt
  zip doesn't cause noisy diffs (see `modules/compute/main.tf`).

## Where to go next

1. Read `modules/networking/main.tf` — the smallest module, good starting point.
2. Follow a value: `var.vpc_cidr` → networking subnets → search/database SGs.
3. Run `make tf-plan` and read the preview before applying anything.
```
