# The fork no longer follows upstream

This repository is a personal fork of akalikbergenov/cyclop. From 2026-10-08, when both stood at 125eb02, it stops merging upstream: an upstream fix that is wanted here is cherry-picked by hand. The removal of Calendar, Notes and Music ([ADR 0002](0002-remove-calendar-notes-music.md)) deletes the files upstream edits most and rewrites its busiest shared ones (`NotchViewModel.swift`, `NotchContentView.swift`, both string tables), so every regular merge would conflict in the same places, while one wanted fix costs one cherry-pick.

## Considered Options

- Keep merging upstream, with the removal kept small in shared files and docs: rejected, the same conflicts come back with every merge.
- Decide later: rejected, it pays the cost of a cramped removal for an option that would rarely be used.

## Consequences

- Upstream's public face stays and is only edited where the removal touches it: the site under `docs/`, the release pipeline, the contributor kit, and README's badges, download and clone links. Those links point at upstream, so README's download link gives upstream's app with all three tabs, and the edited site is not served from the fork.
