# Unix admin CLI user mismatch — 23 October 2026

Source correction: Veil **`ff1e68fb`**.

## Confirmed report

The installed Linux CLI `0.11.44` reproduced `Broken pipe` for
`node dht list` invoked from a root shell while the node service ran under
its dedicated OS account. `node health` failed the same way. Both commands
succeeded when invoked under the service account. The daemon stayed active
with the same PID throughout. The unsigned-config warning also appeared on
the successful invocation, establishing that it did not cause the refusal.

The admin Unix listener's existing same-user credential check drops a
connection from a different OS uid before reading its request. Root can open
the socket, but its uid still differs from the service's uid. The client
previously discovered this through a failed socket write with no useful
explanation. The verified operator command is:

```bash
sudo -u veil -- /usr/local/bin/veil-cli --config /var/lib/veil/node.toml node dht list
```

Use the actual service account when it differs from this example; systemd
exposes it with `systemctl show veil.service -p User`.

## Correction and verification

The Unix admin client now reads the listener's uid through kernel peer
credentials on the platforms where the server enforces that policy. On a
mismatch it explains the node/client uid difference and suggests running the
CLI as the service account. Socket-file ownership is not used as the identity
authority. The server's access check remains in force.

Local checks pass: **9 admin transport tests**, **27 admin protocol tests**
(**6 ignored**), **29 CLI node-command tests**, all-target Clippy for the runtime
and CLI with warnings denied, and rustfmt. The new negative test uses a real
Unix listener's kernel credentials and supplies a different expected client
uid without requiring privileged CI; it verifies rejection before any request
bytes. A positive test exchanges bytes in both directions as the correct user.

The live Linux check used the installed binary and validates the cause and
workaround. The revised diagnostic was verified locally; this cycle did not
install an updated Linux CLI. These checks do not establish full project CI
or resolve the separate file-transfer/route reconstruction failures.

[summary.json](summary.json) contains aggregate observations and verification
scope. Server addresses, hostnames, OS uid values, DHT entries, keys, config
contents and raw command output remain outside this report.
