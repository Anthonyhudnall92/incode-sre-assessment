# Conventions

Short, predictable names and a commit history that explains itself. These apply
to every change in this repo, by people and by tools.

## Commits: every commit records its date and purpose

```
YYYY-MM-DD: <what this commit does, imperative mood>

<why: what was wrong or needed, and what changed to address it>
```

- The subject starts with the date the change was made, then the purpose.
  Whole subject line 72 characters or fewer.
- The body is required. It says *why*, not just what.
- One purpose per commit. Two unrelated fixes are two commits.
- Example:

  ```
  2026-11-01: Fix app crash-loop caused by unreadable /app directory

  COPY --chmod=0444 also gave /app mode 0444, so the non-root user could
  not enter it. Create /app with 0755 before copying files in.
  ```

Enforced by `.githooks/commit-msg`. Enable it once per clone:

```
git config core.hooksPath .githooks
```

## Branches

`<type>/<two-to-four-words>`, lowercase, hyphens, 40 characters or fewer.
Types: `feat`, `fix`, `infra`, `docs`, `chore`.
Examples: `infra/github-oidc-roles`, `fix/app-dir-permissions`.

## Pull requests

- Title: a plain-English description of the change, 60 characters or fewer.
  No type prefixes, emoji, ticket noise or "WIP" (open a draft instead).
  Good: `Add GitHub OIDC roles for CI`. Bad: `feat(infra)!: 🚀 OIDC stuff v2 FINAL`.
- Body: what changed, why, and how it was verified.

## Containers, images and Kubernetes resources

- Names are lowercase, hyphenated and say what the thing is:
  `<app>-<role>`, e.g. `uptime-web`, `uptime-checker`.
  No random suffixes, version numbers, "final", "new" or "test2" in names.
- A container, its Deployment, Service and ServiceAccount share the same name.
- Namespaces are one short word: `uptime`, `argocd`.
- Image tags: `<YYYYMMDD>-<git short sha>`, e.g. `20261101-8ab5151`.
  Never `latest`. Workloads are deployed by digest; the tag is for humans.

## AWS and Terraform names

- `<project>-<env>-<component>`, e.g. `sre-demo-rds`. No repeated words
  (`sre-demo-demo-...`).
- Use fixed names where the resource allows them. `name_prefix` (which appends
  a 26-digit timestamp) only where a name must change on replacement, such as
  security groups and parameter groups with `create_before_destroy`.
