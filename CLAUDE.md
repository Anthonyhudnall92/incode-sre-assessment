# Working in this repo

- Follow CONTRIBUTING.md for commits, branches, PR titles and resource names.
  Every commit subject starts with `YYYY-MM-DD: ` and has a body saying why.
- AWS: always `AWS_PROFILE=incode`. Never commit `*.tfvars`, `backend.hcl`,
  state, plans, or the account ID, domain, IP or email they contain.
- kubectl: use the repo-local kubeconfig (`KUBECONFIG=.kube/config`); the global
  default context on this machine is an unrelated production cluster.
- GitHub: the remote is the personal account Anthonyhudnall92; the repo stays
  private until submission.
