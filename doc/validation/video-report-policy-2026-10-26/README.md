# Anonymous video controller reports

Local correction after the 0.13.93 release; not included in that published tag.

Diagnostic AOT builds previously retained native media counters, while the
controller's detailed snapshot existed only behind the stand history guard.
Reports could therefore show low FPS without its controller phase or probe
interval. The diagnostic build now samples a separate bounded controller event
after processing the current observation and applying pending changes.

Only six source-owned fields are accepted: phase code (startup=0, drain=1,
cruise=2, probe=3), supported/probe-confirmed/queue-pressure flags, finite
throughput in 0–1,000,000 kbit/s and integer probe intervals in 950–3000 ms.
Unknown fields, malformed values, peer maps, history and native clocks are
omitted. The existing five-second sampling interval and journal capacity apply;
native and controller events retain independent sample cadence and exact counts.
Ordinary builds retain their compile-time disabled diagnostic call site.

Validation: 235 focused privacy, report-export and video policy tests passed;
five-file static analysis and whitespace checks passed. The committed CLI
fixture was compiled to a product AOT executable with diagnostics enabled.
It confirmed that the safe controller state is available while stand history
remains empty and canary peer/clock fields are excluded.

Reproduce the AOT check from the repository with resolved packages:

```sh
TMPDIR=/private/tmp/ dart compile exe --packages=.dart_tool/package_config.json \
  -DXVEIL_DIAGNOSTICS=true test/fixtures/diagnostic_video_product.dart \
  -o /private/tmp/xveil-diagnostic-product-check
TMPDIR=/private/tmp/ /private/tmp/xveil-diagnostic-product-check
```

Validation scope is report serialization and product AOT visibility. No call
routing, media adaptation thresholds or relay behavior were changed.
