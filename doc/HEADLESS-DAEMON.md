# xVeil headless daemon

The headless host runs the real deniable store, embedded veil node, messaging
engine and `/v1` automation API in a standalone Dart AOT executable. It does
not start or link a Flutter engine. Build the bundle on the target operating
system:

```sh
scripts/build-headless.sh
```

The bundle is self-contained under `build/headless/bundle/`: the executable is
in `bin/`, native libraries in `lib/`. For development, `VEIL_FFI_DYLIB` and
`XVEIL_HV_DYLIB` may override their locations.

## Provisioning

Create the public, non-secret config and a protected API credential:

```sh
build/headless/bundle/bin/xveil init-config /etc/xveil/headless.json
umask 077
build/headless/bundle/bin/xveil generate-token > /etc/xveil/api.token
```

Edit the JSON paths, ports and bootstrap peers. Passwords, identity phrases and
API tokens are deliberately rejected from JSON and literal CLI arguments. Use
protected files (or a service manager's credential facility):

```sh
build/headless/bundle/bin/xveil run \
  --config /etc/xveil/headless.json \
  --create \
  --password-file /run/credentials/xveil/store-password \
  --identity-phrase-file /run/credentials/xveil/identity-phrase \
  --api-token-file /run/credentials/xveil/api-token
```

`--identity-phrase-file` and `--create` are first-run options. The phrase is
consumed to provision the identity and is never stored. Subsequent starts need
only the store password; issued API tokens are loaded from the deniable store.
An existing GUI identity store is format-compatible, but two processes must
never open the same container concurrently (the native exclusive lock rejects
that safely). A bot should normally use its own identity/store.

Environment overrides for public configuration are `XVEIL_CONFIG`,
`XVEIL_STORE`, `XVEIL_RUNTIME_DIR`, `XVEIL_BLOB_DIR`, `XVEIL_LISTEN_PORT`,
`XVEIL_API_PORT`, `XVEIL_ANONYMOUS`, `XVEIL_OBFS4_PSK_FILE`,
`XVEIL_USE_BUNDLED_SEEDS`. Secret file paths
may be supplied as `XVEIL_PASSWORD_FILE`, `XVEIL_IDENTITY_PHRASE_FILE`, and
`XVEIL_API_TOKEN_FILE`; secret values themselves have no environment option.

### `use_bundled_seeds`: the shared entry nodes

Whether this daemon may reach the network through the operator-run SEED nodes
compiled into the native library. Three states, and the third is not a bug:

* **stated** (`true`/`false`, or `XVEIL_USE_BUNDLED_SEEDS`) — that is the
  answer. `false` composes the node with `builtin_seed_policy = "never"`, so it
  dials nothing but the peers you named yourself, and a daemon with no
  `bootstrap_peers` then reaches nothing at all;
* **absent** — the answer stored in the identity's own space is used
  (`network.bundled_seeds.v1`, written by the GUI app when someone answers the
  question during onboarding). A daemon opened on a container whose owner
  refused the shared seeds does not put them back on;
* absent, on a store that has never answered — the seeds are used, which is what
  every install did before the question existed.

There is deliberately no fourth source. The app keeps a per-profile preference
as its own pre-unlock fallback; that file belongs to an app profile a daemon
does not have, and reading it would drag `package:shared_preferences` — and so
`package:flutter`, and so `dart:ui` — into an AOT binary that cannot have it.
That import is exactly what stopped this daemon building at all in `709f3b9`,
with every app build and the Flutter-free gate still green.

### Secret files, and what they are checked for

Omitting `--password-file` prompts for the password on the terminal with echo
off. That is the preferred path: nothing is written down, so there is no file
for another account to read.

A secret file is the unattended fallback and is refused unless the daemon can
show it is private — not a symlink, a regular file, and on POSIX no permission
bit set beyond the owner's (`chmod 600`). It is also stat-ed before and after
the read and refused if it changed in between; `dart:io` has no
`openat`/`O_NOFOLLOW`, so a swap can be detected but not prevented.

**On Windows none of that can be checked.** Access there is an ACL, and Dart
exposes neither the ACL nor the file's owner, so a secret file used to be read
with nothing examined at all (audit X-10). It is now REFUSED on Windows unless
you restrict it yourself and say so:

```powershell
icacls C:\ProgramData\xveil\store-password /inheritance:r /grant:r "%USERNAME%":R
xveil run --config ... --password-file ... --accept-unchecked-secret-files
```

`XVEIL_ACCEPT_UNCHECKED_SECRET_FILES=1` is the equivalent for a service manager
with no editable command line. Either way the daemon prints a warning naming the
file: the flag records your assertion that it is private, it does not verify it.
On POSIX the flag has no effect and says so — the permission check still runs.

## Running a bot

A bot is not a mode: it is a daemon on its own store. It mints its own identity
on first run, so it has its own key and its own node id, joins a group as a
member in its own right, and everything it posts is signed by it — the group
sees the bot, not whoever runs it.

Two things about the config decide whether that works, and neither announces
itself:

**`bootstrap_peers` must be set.** The node itself joins the network from seeds
compiled into the native, so a daemon with an empty list connects, reports
`connected`, and looks entirely healthy. But the mailbox relays are derived
from this list, and without them the daemon builds no mailbox at all: it never
advertises a key for others to seal to, so nobody can leave anything for it.
It can start conversations and never be reached first — a contact request sent
to it fails at the sender with `PeerUnresolved` and shows nothing on either
side. The daemon warns about this on startup, and `GET /v1/account` reports
`reachableOffline: false`.

**Give it a few minutes before adding it.** Its rendezvous advertisement has to
reach the network before anyone can seal to it. About a minute after startup a
contact request still fails; a few minutes later the same request lands.

The rest is the ordinary contact and group flow:

```sh
# 1. who is it?  (also: reachableOffline)
curl -sH "Authorization: Bearer $TOKEN" localhost:8787/v1/account

# 2. what do I add?
curl -sH "Authorization: Bearer $TOKEN" localhost:8787/v1/account/invite

# 3. either add that invite from your app, or hand the bot YOUR invite and let
#    it ask (this is the bot asking — the target is the OTHER side's invite):
curl -sX POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"target":"veil:bootstrap?..."}' localhost:8787/v1/contacts

# 4. pending requests are listed with their status, so a bot can see and accept
curl -sH "Authorization: Bearer $TOKEN" localhost:8787/v1/contacts
curl -sX POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"peer":"<node id>"}' localhost:8787/v1/contacts/accept
```

Then invite it to a group from the app as you would a person. A group invite
only takes hold once you are contacts — a stranger's invite is refused rather
than silently materialising a group — so do the contact step first.

Uploads can say what they are, so a bot posts a photo as a photo rather than as
a generic file: `POST /v1/groups/files` accepts `kind` with `width`/`height`
for an image or video and `durationMs` for a voice message or video note.
Metadata that contradicts the kind is refused rather than published, because
the row is signed and cannot be corrected afterwards.

## systemd service

Provision the identity once with `--create`, then remove the phrase credential
from the steady-state service. A minimal hardened unit for a dedicated `xveil`
user is:

```ini
[Unit]
Description=xVeil headless daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=xveil
Group=xveil
StateDirectory=xveil
RuntimeDirectory=xveil
UMask=0077
LoadCredential=store-password:/etc/xveil/store-password
LoadCredential=api-token:/etc/xveil/api-token
ExecStart=/opt/xveil/bin/xveil run --config /etc/xveil/headless.json --password-file %d/store-password --api-token-file %d/api-token
Restart=on-failure
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/var/lib/xveil /run/xveil
LimitMEMLOCK=infinity

[Install]
WantedBy=multi-user.target
```

Keep `/opt/xveil/bin` and `/opt/xveil/lib` together: the executable resolves
the bundled FFI libraries from the sibling `lib/` directory. SIGINT/SIGTERM
first closes the API, messaging engine, embedded node and encrypted store, then
explicitly terminates the standalone process so residual native worker threads
cannot hold service shutdown open.

## API and privacy boundary

The daemon serves the same authenticated API, WebSocket event feed and
loopback webhook implementation as the GUI. HTTP always binds only
`127.0.0.1`; expose it remotely only through a separately authenticated tunnel.
Calls return HTTP 501 because the headless host has no audio/video media engine.
Messaging, contacts, files, groups, OpenAPI, scoped tokens, WebSocket events
and loopback webhooks use the normal production code paths. Group list/create
and message read/post are available at `/v1/groups` and
`/v1/groups/messages`; incoming group messages also appear in the WebSocket
and webhook feed as `group_message` events. The daemon uses the same signed
group log and epoch-E2EE service as the GUI, not an API-only shadow store.

SIGINT or SIGTERM stops the API, mailbox and node, closes the encrypted store,
and removes the identity-free runtime socket directory.
