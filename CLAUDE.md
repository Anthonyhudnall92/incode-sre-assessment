# Working in this repo

- Follow CONTRIBUTING.md for commits, branches, PR titles and resource names.
  Every commit subject starts with `YYYY-MM-DD: ` and has a body saying why.
- AWS: always `AWS_PROFILE=incode`. Never commit `*.tfvars`, `backend.hcl`,
  state, plans, or the account ID, domain, IP or email they contain.
- kubectl: use the repo-local kubeconfig (`KUBECONFIG=.kube/config`), never the
  global one; the scripts already do. Always target the EKS context explicitly.
- CI: GitHub Actions assumes AWS roles through OIDC (bootstrap/github-oidc.tf).
  Applies run in the `production` environment and wait for approval.
