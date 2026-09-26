# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- **`stripNonClan` removed**: generator `prompts` were being stripped before
  reaching `clan.core.vars.generators`, causing `$prompts` to be unbound at
  runtime. User-provided prompts now properly instruct clan-core to set
  `$prompts` when executing generator scripts.
- **Auto-generated prompts match clan-core flat format**: removed the `input`
  wrapper sub-attribute from auto-generated prompt entries. Clan-core expects
  the flat format `prompts.<file> = { description, type, persist }`, not
  `prompts.<file>.input = { ... }`. The old `input` wrapper was masked by
  `stripNonClan` and now surfaces during option validation.
- **Prompt auto-generation scoped to explicit `promptType`**: only files with
  an explicit `promptType` attribute get auto-generated prompts. Files without
  `promptType` no longer generate stale prompt entries. This fixes the issue
  where auto-generated secrets (e.g. via `runtimeInputs` + `openssl`) would
  leak unnecessary prompts into clan-core.
