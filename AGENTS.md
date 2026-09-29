# Working rules

- Commit project edits at the end of each work cycle. Do not sign or push commits unless the user asks.
- After a stand test, close the app instances you started and verify their processes have exited.
- Launch macOS stand apps with `TMPDIR=/private/tmp/`. The host's default temporary directory may be on `/Volumes/cfb`, which triggers repeated removable-volume permission prompts for rebuilt ad-hoc apps.
