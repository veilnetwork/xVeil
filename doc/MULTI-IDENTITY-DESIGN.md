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

**Duress decoy (master level).** The user pre-configures a *decoy master* space
with plausible identities and "correct"-looking chats. Under coercion they give
the **duress password**, which opens the decoy master. Its roster lists only
identities that are **safe to reveal** — pure decoys and/or *shared innocuous*
identities (e.g. a real "relatives" identity also kept in the real master, §3b);
**never** the real master or any sensitive identity. So coercion yields a
believable, complete-looking setup — including some genuine harmless chats —
while revealing nothing sensitive. The decoy master and the real master are
separate spaces; a sensitive identity is never referenced from the decoy.

## 3. Core principle: identity ≡ space

An **identity** is exactly one hidden-volume space. Everything that identifies
the user lives **inside** that space:

- storage: messages, contacts, settings, files (already there);
- **the veil node keypair** (Ed25519 private/public, node_id, PoW nonce);
- node parameters needed to boot (listener, ipc, mining params);
- username + its PoW claim.

Selecting an identity = unlocking its space with its password. There is **no
enumerable list of identities on disk or outside a master space** — that would
break deniability. Unlock is password-only; a non-matching password is
`AuthFailed`, indistinguishable from "no such space" (invariant already honoured
by the lock screen).

## 3b. Two unlock modes: single identity and master

A password can open either kind of space (indistinguishable from outside):

- **Identity password → one identity.** Opens that identity's space directly.
  The simple, single-identity user never needs a master.
- **Master password → a roster of identities.** A **master space** is an
  app-layer space whose contents are a roster: a list of
  `{label, child SpaceKeys}` entries pointing at identity spaces it manages. The
  master opens any child via `open_space_with_keys(child_keys)` — no per-child
  password prompt. From a master session the user can see, switch between, and
  act as any identity in the roster.

The roster lives **inside** the master space (encrypted, deniable), never on
disk. Identity spaces remain openable *directly* by their own password too (so
the same identity works in single mode and as a master's child).

**A child may belong to several rosters.** The same identity's `SpaceKeys` can
be recorded in more than one master — e.g. an innocuous "relatives" identity
that lives in *both* the real master and the decoy master. Under duress the
decoy then shows genuine, believable chats (real conversations with real people),
which makes the decoy far more convincing, while the sensitive identities stay
hidden. This is safe because of one invariant:

> **References are one-directional: master → child. A child never references its
> master(s).** Identity spaces are reference-free leaves, so opening one reveals
> nothing about which masters point at it or whether other masters exist.

Caveat for the user: a shared child's **full content is exposed** whenever any
master that lists it is opened — including under duress. So only share genuinely
innocuous identities into a decoy; never one whose chats could implicate you or
hint at the hidden set.

## 3c. Acting as an identity (send-as)

Every **conversation is owned by exactly one local identity** — the node it is
conducted under — and is stored in that identity's space. Starting a chat
prompts "as which identity?" (in master mode; trivial in single mode). Messages
to that conversation always send via the owning identity's veil node, so a
contact only ever sees the node_id you chose for them. A reply arrives on the
identity it was addressed to and lands in that identity's space.

Open question (§7): in master mode, do we run **all roster identities' nodes
simultaneously** (you receive on every identity at once) or **one active node**
that you switch (only the active identity is online)? Simultaneous is the better
messenger UX but heavier and more network surface; switching is simpler.

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

**Unlock (either mode — the app can't tell which kind a password opens)**
1. Enter password → `open_space(password)`. No match → `AuthFailed` → generic
   "wrong password". (No hint about how many spaces exist, or whether this is an
   identity or a master.)
2. Inspect the opened space: identity space → boot its node (read `node:identity`,
   boot in memory). Master space → load the roster; the user picks an identity to
   act as, the app opens that child via `open_space_with_keys` and boots its node.

**Create / configure a master**
1. Under a master session (or at master creation), `add_space(master_password)`
   creates the master space; its roster starts empty.
2. Adding an identity to the master: create the identity space (as above) and
   record its label + `SpaceKeys` in the master roster. The app has the child
   keys at creation time, so no separate password round-trip is needed.
3. **Decoy master:** same mechanism with the duress password; populate its roster
   with decoy identities and/or *shared innocuous* identities (a real child can be
   added to both rosters — §3b). The app must never write a *sensitive* child's
   keys into the decoy roster (enforced by keeping master sessions separate — you
   build the decoy while *in* the decoy master, and choose which children to add).

**Lock**
1. Stop the node(s), zeroize key material (including any cached child SpaceKeys),
   close the space(s).

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

**Also required for the master model (all backed by existing core):**
- `open_with_keys(path, SpaceKeys)` — exposes `Container::open_space_with_keys`
  (mod.rs:469) so a master opens its children without their passwords.
- A way to **materialize a child's `SpaceKeys`** for the master to store —
  either export from an open handle or derive from the child password at
  creation time (`SpaceKeys` = derive.rs:48). These keys are sensitive
  (per-space decryption root); they live only inside the master space.
  `SpaceKeys` must cross the FFI as opaque bytes, never logged.

### 6.2 veil — boot the node without a disk config (the deniability-critical part)
Today `veil_node_start(config_path)` reads a **file**, and `veil-cli config init`
writes the mined `[Identity]` (Ed25519 `private_key` + `node_id` + PoW `nonce`)
into that file. Both must change so keys never touch disk.

- **`veil_config_init` (in-process identity mining)** — expose what
  `veil-cli config init` does (keypair via `crypto::generate_keypair`, ≥24-bit
  PoW nonce mining) as an FFI that **returns** the identity material in memory
  instead of writing a config file. xVeil stores it in the space's
  `node:identity` blob. Security-critical; mobile onboarding needs it anyway.
- **Boot from in-memory identity — two options:**
  - **(A, no new FFI)** Reuse the existing `veil_node_start_deferred` (boots
    ephemeral, no config file) + push the real config — assembled in memory from
    the space's `node:identity` — over the node's **admin IPC** (`apply_config`,
    already on the backlog). Smallest veil-side change; relies on the deferred +
    apply path being complete.
  - **(B, new FFI)** Add `veil_node_start_from_config_bytes(bytes)` that parses
    an in-memory TOML (no path) and boots directly. Cleaner boot, but the node
    runtime currently takes a config *path* (`start_thread(Some(path), …)`), so
    this needs the runtime to accept a parsed `Config` object.
  *Recommendation:* try (A) first (no new FFI, exercises deferred+apply which we
  want anyway); fall back to (B) if deferred+apply can't carry the full identity.

Also audit: the embedded node must not persist identity-bearing state to disk —
admin/ipc socket **paths** must be ephemeral and identity-free, DHT is in-memory
already (rocksdb opt-in), confirm no peer cache / logs leak.

### 6.3 xVeil — wiring
- Storage: `node:identity` blob read/write in the space; `_createOrOpen` uses
  `add_space` (replacing the interim stop-gap).
- Boot: `RealVeilStack` reads node keys from the unlocked space and starts the
  embedded node via the in-memory boot FFI, instead of pointing at a config file.
- Onboarding: "create identity" mines in-process (progress UI) and stores into
  the (new) space.
- One active identity at a time (see §7).

## 7. Decisions (updated per review 2026-06-15)

1. **Both modes supported** (confirmed): single identity *and* a master space
   that manages several. Plus an explicit **send-as-identity** mechanism: each
   conversation is owned by one identity; starting a chat picks the identity
   (§3c).
2. **Master mode node activation — DECIDED: one active node + fast switch.**
   Only the active identity is online; switching identity swaps the running node.
   The data model is per-identity from the start, so running all roster nodes
   simultaneously can be enabled later (Phase 3) without a schema change.
3. **Distinct password per identity** (confirmed): the model can't deniably
   dedupe passwords (AuthFailed conflation); UX steers to distinct passwords,
   `add_space` adopts on exact `SpaceAlreadyExists` collision.
4. **Decoy / duress is in scope (master level)** (confirmed): a duress password
   opens a pre-built **decoy master** whose roster holds only decoy identities
   with plausible chats; it never references the real master/identities (§2, §5).
5. **Username/PoW + node keypair** live inside each identity's space.

## 8. Phasing

- **Phase 1 (closes the leak — single identity, fully deniable):** `add_space`
  FFI + storage wiring + node keypair in-space + in-memory node boot + in-process
  mining. After this, §2's invariant holds for one identity. Do **not** ship
  multi-identity storage without the node-boot half, or §4's headline leak
  remains.
- **Phase 2 (master + send-as + decoy):** `open_with_keys` + `SpaceKeys` export
  FFI; master-space roster; per-identity conversation ownership + send-as picker;
  pre-built **decoy master** for duress. One active node + fast switch.
- **Phase 3:** simultaneous per-identity nodes, multi-device sync.

## 9. Deniability invariant checklist (acceptance)

- [ ] No plaintext private key or node_id anywhere on disk.
- [ ] No file whose presence/contents proves a specific identity exists.
- [ ] Count of identities not derivable from the container or any sidecar.
- [ ] A single coerced password opens exactly one space and reveals nothing
      about the others.
- [ ] The decoy master's roster references only safe-to-reveal identities (pure
      decoys + shared innocuous ones); opening it under duress cannot reach the
      real master or any sensitive identity.
- [ ] References are one-directional (master → child); a child never references a
      master, so a shared child reveals nothing about which masters list it or
      whether others exist.
- [ ] A master and its child rosters live only inside spaces — no on-disk index,
      no cross-space reference an adversary could follow.
- [ ] Node runtime writes nothing identity-bearing to disk.
- [ ] Lock screen does not distinguish wrong-password from no-space.
