# origaiTV

This repo is `origaitv-iso`: the installer ISO for origaiTV, built on top of Omarchy. It's a fork of `omacom/omarchy-iso` that follows upstream's `quattro` whenever Omarchy has a new stable release (ADR-026). The upstream commit it's on is in `.github/omarchy-base`, and the Omarchy release that went with it in `.github/omarchy-release`. It builds Omarchy's own installer with Omarchy's own packages, and adds origaiTV's signed packages beside them (ADR-025). Omarchy's own `AGENTS.md` and README here still apply. This file adds what's different for origaiTV, and when the two disagree, this file wins.

The plan lives in `../agentic-tv-os`: read `HANDOFF.md` first ("Next: stage 0" is the to-do list here). origaiTV's skills live in `../origaitv-os/.claude/skills/`. Start the session in `origaitv-os` with this repo added, or read them there. The ones that matter most here are:
- `origaitv-quality-gates`;
- `origaitv-acceptance-tests` (the image test);
- `origaitv-install-scripts`.

## Rules

- **Never edit upstream files.** Only add: our workflows, the build step that adds origaiTV's packages and logo (`configs/airootfs/root/customize_airootfs.sh` and `configs/airootfs/usr/share/origaitv-iso/`), and our tests in `test/origaitv/`. Check with `bin/origaitv-check`; its first check is the same as `git diff --diff-filter=MDR --name-only "$(cat .github/omarchy-base)"...HEAD` printing nothing.
- **What the ISO shows is origaiTV's, at build time only** (ADR-027, ADR-028). `bin/origaitv-iso-brand` changes the name, volume label and boot menu titles in the working tree for one build, and `test/origaitv/image/ci` puts upstream's files back. The live system's greeter, step headers and finish screen are changed by `customize.sh` inside the ISO. Each change stops the build if upstream has moved its line; fix the step, never the upstream file.
- **Upstream's own workflows stay off,** except the ones `.github/upstream-workflows-kept` names (its unit tests). They publish to Omarchy's bucket or use runners we don't have. They're switched off through the API, never by editing them, and the Omarchy sync switches off any new ones.
- **The owner name is never in code.** Workflows read it from GitHub's own context, so the repos can move to an organisation later.
- **Build and test the ISO in CI only.** The Mac can't run the x86_64 ISO, and it has little free disk. The ISO is about 6.4 GB, so it travels as a workflow artifact, not a release asset.
- **No secrets** in the repo. The signing key and test keys live as GitHub Actions secrets.
- **Copy**, commit messages included, reads like an indie dev talking about the project: first to the person who'll use it, then to another dev. Short sentences, plain words, no inside references (ADRs, acceptance ids) in public text or commit subjects, "coming soon" for planned things, "Powered by Omarchy", and no em dashes anywhere. The `origaitv-copy` skill in origaitv-os has the rules and examples.
- **Commit** with this repo's own git identity. Leave out any AI attribution: no Co-Authored-By or session trailers in commit messages, and no "Generated with" line in pull requests. Log progress in `../agentic-tv-os/LOG.md`.
