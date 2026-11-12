# Security policy

This is the default policy for repositories under this account that do not have their own
`SECURITY.md`.

## Reporting a vulnerability

Use **Report a vulnerability** on the repository's Security tab. That opens a private report
visible only to the owner. Do not open a public issue or pull request that describes a
vulnerability or an exposed secret.

If a repository has no such button, it is private or reporting is off: contact the owner
(`@cyberflamingo`) directly on GitHub.

Only the default branch is supported.

## How repositories are protected

- Third-party code is pinned: GitHub Actions and pre-commit hooks to full commit SHAs, language
  dependencies to a lockfile where the project has one.
- Workflow tokens default to read-only, and Actions cannot approve pull requests.
- Dependabot alerts and security updates are on. Secret scanning and push protection are on where
  GitHub offers them for the repository.
- Public repositories use rulesets: pull request with review, linear history, signed commits, and
  immutable `v*` tags. Private repositories on a free plan cannot, so they rely on CI and
  convention. Each repository that skips a control records why.

The settings are applied by [`scripts/harden-repo.sh`](scripts/harden-repo.sh) in this repository.
