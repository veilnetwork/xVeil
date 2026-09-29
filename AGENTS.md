# Working rules

- Commit project edits at the end of each work cycle. Do not sign or push commits unless the user asks.
- After a stand test, close the app instances you started and verify their processes have exited.
- Launch macOS stand apps and run Flutter tests with `TMPDIR=/private/tmp/`. The host's default temporary directory may be on `/Volumes/cfb`: rebuilt ad-hoc apps repeatedly request removable-volume access there, and folder-sync security tests correctly reject fixtures beneath its group-writable parent.
