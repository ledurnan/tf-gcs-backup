# 0006: Ownership of a personal repository used by work projects

- Status: Proposed, open

## Context

The repository lives in a personal account and is intended for personal
and work projects alike. Work infrastructure would then depend on code
whose ownership and continuity sit with one person.

## Options

1. **Keep it personal**, and accept the dependency knowingly. Simplest.
   If someone else must maintain a work project's backups, they need
   access to this repository.
2. **Move it to an organisation** that the work projects belong to, and
   consume it from personal projects instead.
3. **Personal upstream, work fork**: work projects consume a fork their
   organisation controls, pulling from upstream at tags.

## Decision

Not yet made. Record it here before a work project depends on a tag.
