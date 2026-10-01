# 0006: Ownership of a personal repository used by work projects

- Status: Accepted

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

**Keep it personal (option 1).** Work projects may depend on this
repository as they would on any other external project: at a pinned
release, with the same care they give any third-party dependency.

## Consequences

- No work organisation owns or maintains this repository, and none has
  any say in its roadmap. A work project that needs a change asks for it
  upstream, or forks, as it would with any external project.
- A work project pins a release (ADR 0005) and owns its own upgrades.
  Nothing here changes under a consumer that hasn't chosen to upgrade.
- If continuity becomes a concern for a particular work project, it can
  fork (option 3) at that point. Because consumers pin a URL and a tag,
  switching to a fork changes only those pins.
