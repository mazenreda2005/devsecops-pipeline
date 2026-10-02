# Demo: watch the pipeline block a bad change

This folder is excluded from scanning. To show a client the gates working,
copy one of these into the scanned paths on a branch and open a pull request.

| Copy this | To | Gate that fails |
|---|---|---|
| `insecure.tf.example` | `infra/insecure.tf` | Checkov: public, unencrypted S3 bucket and SSH open to the world |
| `Dockerfile.insecure` | `app/Dockerfile` | Trivy: old base image with known CVEs. Checkov: runs as root, no healthcheck |
| `bad_code.py.example` | `app/bad_code.py` | Bandit: shell injection, Flask debug mode, bind to all interfaces |

For the secrets gate, add a line like `aws_secret_access_key = <40 random chars>`
to any file. Gitleaks flags it, even if you delete it in a later commit,
because it scans the whole history. Use a throwaway branch.
