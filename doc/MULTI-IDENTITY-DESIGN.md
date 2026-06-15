# Multi-identity & deniability — design

Status: **draft for review** (no code yet). Supersedes the interim crash-fix
in `_createOrOpen` (commit 93a4430), which only prevents a crash and is *not*
the target behaviour.

## 1. Goal

One container **file** holds N **identities**, each keyed by its own password,
and an adversary who seizes the device **cannot tell how many identities exist**
(or that more than one does). This is the whole point of hidden-volume: spaces
are indistinguishable from garbage padding. xVeil must not undo that at any
other layer.

Concretely, "create a new identity" must add a *new parallel deniable space* to
the existing container — not fail, not adopt the old one, not create a second
file.

## 2. Threat model (what the adversary must NOT learn)

Adversary = has the device at rest, full disk image, one coerced password
(duress). They must not be able to prove, from anything on disk, that:

- more than one identity exists;
- a *specific* identity (node_id, username, contacts) exists;
- which spaces are "real" vs decoy.

A coerced password reveals **only the one space it opens**. Everything else stays
indistinguishable from padding.

## 3. Core principle: identity ≡ space

An **identity** is exactly one hidden-volume space. Everything that identifies
the user lives **inside** that space:

- storage: messages, contacts, settings, files (already there);
- **the veil node keypair** (Ed25519 private/public, node_id, PoW nonce);
- node parameters needed to boot (listener, ipc, mining params);
- username + its PoW claim.

Selecting an identity = unlocking its space with its password. There is **no
enumerable list of identities** anywhere — that would break deniability. Unlock
is password-only; a non-matching password is `AuthFailed`, indistinguishable
from "no such space" (invariant already honoured by the lock screen).

## 4. On-disk artifact audit — what leaks today

| Artifact | Identity-bearing? | Target |
|---|---|---|
| hidden-volume container (one file) | No — deniable by design | **keep** |
| `config.toml` `[Identity].private_key` / `public_key` / `node_id` / `nonce` | **YES — plaintext private key + node_id on disk** | **must move INTO the space**; node boots from in-memory config |
| `config.toml` listener / ipc / bootstrap / transport | Partly (ports, bootstrap peers) | derive at boot from in-space params + ephemeral runtime values |
| veil node runtime state (DHT) | Potentially | already in-memory (rocksdb made opt-in); **audit** for any disk writes |
| veil logs / `admin_socket` / `ipc.socket_uri` paths | Path names can hint | ephemeral per-session paths, no identity in the name; no secrets in logs |
| `shared_preferences` "onboarded" bool | No (only "app was set up") | keep (per SECURITY-NOTES) |

The headline leak is `[Identity].private_key` sitting in a plaintext file. Even
with multi-space storage, that file alone proves an identity exists. So the
storage change (§6.1) is **necessary but not sufficient** — the node-boot change
(§6.2) is what actually closes the leak. Build them together or deniability is
only half-real (this is why "design the whole thing first").

## 5. Lifecycle flows

**First run / first identity**
1. Pick password P1.
2. `HvSpace.create(path, P1)` → fresh container + first space.
3. Mine the veil node identity **in-process** (PoW; see §6.2 `veil_config_init`).
4. Write the node keypair + params into the space (a `node:identity` KV blob).
5. Boot the embedded node from that in-memory keypair (no file).

**Create an additional identity (the case that crashes today)**
1. Pick a *new* password P2 (must differ from P1; the model can't dedupe
   deniably — see §7).
2. `add_space(path, P2)` → new parallel space in the same file (§6.1).
3. Mine + store node identity in the new space (as above).

**Unlock**
1. Enter password → `open_space(password)`. No match → `AuthFailed` → generic
   "wrong password". (No hint about how many spaces exist.)
2. Read `node:identity` from the space → boot embedded node from it in memory.

**Lock**
1. Stop the node, zeroize key material, close the space.

## 6. Required changes, by layer

### 6.1 hidden-volume FFI — `add_space` (small, reuses audited paths)
Core already has `Container::create_space(password)` (adds a parallel space,
errors `SpaceAlreadyExists` on password collision) and the rt helper
`OwnedSpace::wrap_create` (calls `create_space`). The FFI only exposes
fresh-container `create` and existing-space `open`. Add one constructor:

```rust
// open an EXISTING container, then create a NEW space in it
let container = Box::new(Container::open(&p)?);
let inner = OwnedSpace::wrap_create(container, &password)?; // create_space
```

Then `HvSpace.addSpace(...)` in the Flutter plugin + regen bindings. xVeil
`_createOrOpen` (create=true): file absent → `create`; file present →
`add_space`; `SpaceAlreadyExists` → adopt via `open`. Per hidden-volume
conventions: CHANGELOG `[Unreleased]`, EN↔RU doc actualization, a test.

### 6.2 veil — boot the node without a disk config (the deniability-critical part)
Today `veil_node_start(config_path)` reads a **file**, and that file holds the
plaintext private key. Two FFI additions on the veil side:

- **`veil_config_init` (in-process identity mining)** — already flagged
  security-critical. Mines the Ed25519 identity + ≥24-bit PoW nonce in-process
  and returns the keypair/params as bytes, so onboarding never shells out and
  never writes keys to disk. Mobile onboarding needs this anyway.
- **`veil_node_start_from_config_bytes(bytes)`** (or pass keypair + params
  directly) — boot the embedded node from an in-memory config assembled from
  the space's stored keypair. No `config.toml` on disk. Runtime-only values
  (listener port, ephemeral socket paths) are filled at boot.

Also audit: the embedded node must not persist identity-bearing state to disk
(DHT is in-memory already; confirm no peer cache / logs leak).

### 6.3 xVeil — wiring
- Storage: `node:identity` blob read/write in the space; `_createOrOpen` uses
  `add_space` (replacing the interim stop-gap).
- Boot: `RealVeilStack` reads node keys from the unlocked space and starts the
  embedded node via the in-memory boot FFI, instead of pointing at a config file.
- Onboarding: "create identity" mines in-process (progress UI) and stores into
  the (new) space.
- One active identity at a time (see §7).

## 7. Open decisions (recommendations)

1. **One active identity at a time** (recommended) vs several simultaneously.
   Unlock one space → run one node. Simpler, and matches "switch identity =
   re-unlock". Multi-identity-simultaneous and multi-device are separate, later.
2. **Distinct password per identity, enforced by the user, not the system.**
   The model cannot deniably check "does this password already have a space"
   without trying to open (which is the AuthFailed conflation). If two
   identities share a password, `open_space` is ambiguous. So the UX must
   steer toward distinct passwords; the system can't guarantee it without
   leaking. `add_space` does detect an exact collision (`SpaceAlreadyExists`)
   and we adopt in that case.
3. **Decoy / duress (master space)** — phase 2. A "duress password" opens a
   plausible decoy identity. Out of scope for the first cut.
4. **Where username/PoW lives** — inside the space with the node identity.

## 8. Phasing

- **Phase 1 (closes the leak):** `add_space` FFI + storage wiring + node keys
  in-space + in-memory node boot + in-process mining. After this, the
  deniability invariant in §2 actually holds. Do not ship multi-identity
  storage without the node-boot half, or §4's headline leak remains.
- **Phase 2:** decoy/duress space, multi-device sync, identity switcher UX.

## 9. Deniability invariant checklist (acceptance)

- [ ] No plaintext private key or node_id anywhere on disk.
- [ ] No file whose presence/contents proves a specific identity exists.
- [ ] Count of identities not derivable from the container or any sidecar.
- [ ] A single coerced password opens exactly one space and reveals nothing
      about the others.
- [ ] Node runtime writes nothing identity-bearing to disk.
- [ ] Lock screen does not distinguish wrong-password from no-space.
