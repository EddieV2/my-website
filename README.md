# evartanessian.dev — personal site

Static, dependency-free personal site for Edward Vartanessian — software engineer
(platform & infrastructure). No frameworks, no build step. The site is its own
demo: the infrastructure serving it is defined in this repo.

> **How it was built:** in pair-programming sessions with an AI assistant
> (Claude), the way I build everything now. No site builders, no templates,
> no frameworks — and no pretending otherwise. I review, own, and maintain
> every line.

## Stack

- Framework-free HTML + CSS + a little vanilla JS
- Self-hosted variable fonts (Space Grotesk + Inter, latin subset) — zero
  third-party requests
- Case studies under `work/`
- **Hosting: S3 (private, OAC-only) behind CloudFront** — HTTPS via ACM,
  HTTP/3, strict security headers (HSTS preload + CSP), clean-URL + www-redirect
  CloudFront Function, styled 404 — all defined in `terraform/`
- **Deploys: GitHub Actions via OIDC** (`.github/workflows/deploy.yml`) — the
  workflow assumes a repo-scoped IAM role; no AWS keys stored anywhere
- **Observability, publicly demoed** (`/observability.html`): custom 2KB RUM
  beacon (`rum.js` — Web Vitals via PerformanceObserver, honors DNT, no cookies/IDs)
  → CloudFront `/rum` behavior → Lambda → CloudWatch EMF; synthetic probes every
  5 min; an hourly publisher Lambda computes SLO status + error budget and writes
  `status.json` (never touched by deploys). SLOs: 99.9%/30d availability,
  p75 LCP < 1.5s. All in `terraform/observability.tf` + `terraform/lambda/`.
- Word version (for Workday and other ATS that parse `.docx` more reliably):
  strip the on-screen `[FILL IN]` spans, then
  `pandoc /tmp/resume-clean.html -f html -t docx -o Edward-Vartanessian-Resume.docx`
- `resume.pdf` is generated from `private/resume-print.html`:
  `"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless \
   --no-pdf-header-footer --print-to-pdf=resume.pdf private/resume-print.html`
  (the yellow [FILL IN] spans are hidden by print CSS)

## Deploy runbook (first time)

1. **Provision AWS** (waits mid-apply for DNS validation — that's expected):

   ```sh
   cd terraform
   terraform init
   terraform apply
   # While it waits on aws_acm_certificate_validation:
   #   create the CNAMEs from the `acm_validation_records` output at the
   #   DNS provider (DNS-only / not proxied). Apply finishes on its own.
   ```

2. **Point DNS at CloudFront** (values from `terraform output`):
   - apex `evartanessian.dev` → ALIAS / flattened CNAME → `cloudfront_domain`
   - `www` → CNAME → `cloudfront_domain`
   - (Both DNS-only / grey-cloud if the DNS host is Cloudflare — never proxy
     in front of CloudFront.)
   - `evartanessian.com` → registrar-level 301 forward to `https://evartanessian.dev`

3. **Wire the repo** (after `gh repo create` / push):

   ```sh
   gh variable set AWS_ROLE_ARN --body "$(terraform output -raw deploy_role_arn)"
   gh variable set S3_BUCKET --body "$(terraform output -raw bucket_name)"
   gh variable set CLOUDFRONT_DISTRIBUTION_ID --body "$(terraform output -raw cloudfront_distribution_id)"
   ```

   Then every push to `main` deploys: OIDC → `s3 sync` (immutable cache on
   assets, 5-min cache on pages) → one `/*` CloudFront invalidation (free at
   this volume; versioned filenames are the at-scale alternative).

   Note: if this AWS account already has the GitHub OIDC provider, apply with
   `-var create_oidc_provider=false`. After the repo exists, optionally pin the
   trust policy tighter with `-var github_repository_id=$(gh api repos/EddieV2/my-website --jq .id)`.

## Local preview

```sh
python3 -m http.server 8080   # then open http://localhost:8080
```

`private/` is git-ignored working material and never ships with the site.
