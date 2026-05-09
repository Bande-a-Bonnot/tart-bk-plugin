# Foundry Tart BuildKite plugin

Runs a BuildKite command inside an ephemeral Tart VM.

This source tree is the canonical source for the external plugin repo used by the live pipeline (`github.com/Bande-a-Bonnot/tart-bk-plugin#<commit-sha>`). BuildKite must load this as a non-vendored plugin so its `checkout` hook is available before repository checkout. The live pipeline pins an immutable commit SHA; the pinned SHA is recorded in `foundry/buildkite/pipeline.foundry-agent.yml` and the monorepo's VM isolation docs.

## Critical hook precedence

BuildKite hook precedence is agent → plugin → repository. If the Mac mini has an agent-level `~/buildkite/hooks/checkout`, that hook can prevent this plugin's `checkout` hook from suppressing the host checkout. Before live cutover, remove the agent checkout hook or replace it with a shim that exits 0 for `BUILDKITE_PIPELINE_SLUG=foundry-agent`.

## Secret boundary

- Doppler SA token: read by the host plugin and sent to `/usr/local/bin/foundry-vm-bootstrap` over SSH stdin only.
- GitHub App PEM: fetched inside the VM into a shell-local variable, used to mint an installation token, then unset.
- Staged `.env.sh` and `.cmd.sh`: may contain short-lived `BUILDKITE_AGENT_ACCESS_TOKEN` and `FOUNDRY_PROMPT_PULL_TOKEN`; must never contain Doppler token or PEM material.
- Persistent shared mount: only `pi-auth:/Users/thomas/.pi/agent` plus per-job scratch. Tart directory shares are read-write by default; `:ro` is supported, `:rw` is not.

## Publication discipline

After changing this tree:

1. Publish the exact contents to the external plugin repo.
2. Record the resulting external commit SHA in the monorepo docs.
3. Point `foundry/buildkite/pipeline.foundry-agent.yml` at that commit SHA, not a movable branch/tag.
4. Run `foundry/buildkite/scripts/check-tart-plugin-drift.sh` before committing.

Do not change the pipeline ref to a commit whose tree has not been checked against this directory.
