# Neutral node labels in current fixtures and reachable history

The pre-release privacy audit found one operator-specific node label in four
test fixtures, including eleven historical blob versions. The earlier staged
check did not cover these unchanged files. A stopped repeated-tree history scan
is not counted as a passing audit.

The current fixtures now use `test-edge`. Their existing Flutter suite passes
**77 tests**, without skips, with `TMPDIR=/private/tmp/`. Only fixture labels and
their expected results change; application configuration, node addresses,
protocols and runtime implementation do not change.

An isolated mirror replaces only the eleven identified blobs. The resulting
reachable blob inventory equals the original inventory minus those versions plus
their exact neutral replacements. Direct tree references used by local change
checkpoints are rewritten too: commit-only filtering initially left four old
versions reachable through these references. That intermediate result is not
qualified. Both working trees remain clean; the secondary tree receives only
the same four fixture changes.

The final audit reads each unique reachable object once, checks text blobs,
commit/tag metadata and referenced paths against the private literal/regex
policy, and has a positive scanner control. The final xVeil graph passes;
Veil and hidden-volume pass separately. Binary objects are excluded from this
text-history audit; final release artifacts still require their binary/privacy
gates. The 439 frozen media-build inputs retain their tested hashes.

The published references are updated atomically with an explicit old-value lease
for every changed reference: **121 tags and three branches**. A protected-main
rejection changed none of them. The subsequent operation restores the complete
original branch protection, verified by independent reads; an independent
rollback watchdog is armed during the operation and exits after restoration.
All remote head/tag values match the planned result. Existing release assets are
not uploaded or replaced, and no historical release build is started.

No garbage collection or reflog expiration is performed, as requested by the
owner. Unreachable local objects and hosting caches are not claimed erased.
No application window, OS input, device installation, running user application
or seed service is changed.
