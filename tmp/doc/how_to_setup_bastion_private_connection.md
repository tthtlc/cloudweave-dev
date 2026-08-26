# How to Set Up Bastion → Private Server SSH Connection

## Problem

Individually, both SSH connections work:
- `ssh -i key.pem ubuntu@<bastion-ip>` — succeeds
- `ssh ubuntu@<private-ip>` (from inside the bastion) — succeeds

But the combined ProxyJump command **fails**:

```bash
ssh -i key.pem -J ubuntu@<bastion-ip> ubuntu@<private-ip>
# Permission denied (publickey) — at the bastion level
```

## Lessons Learned

### Lesson 1: `-i` does NOT propagate to the jump host with `-J`

**Root cause**: When using `-J` (ProxyJump), OpenSSH treats the jump host and the final target as separate hosts. The `-i` flag only applies the identity file to the **final target**, not the intermediate jump host.

With the failing command:
```
ssh -i libcloud-private-key.pem -J ubuntu@47.129.237.95 ubuntu@10.0.16.241
```

- The key `libcloud-private-key.pem` is offered to `10.0.16.241` (final target) ✅
- The key `libcloud-private-key.pem` is **NOT** offered to `47.129.237.95` (jump host) ❌
- The jump host falls back to default keys (`~/.ssh/id_rsa`, etc.) which are rejected ❌

This was confirmed via verbose debug output (`ssh -vvvvvvvvvvv`):

| Context | Key offered to bastion? |
|---|---|
| Direct: `ssh -i key.pem ubuntu@47.129.237.95` | ✅ "Will attempt key: …libcloud-private-key.pem explicit" |
| With `-J`: `ssh -i key.pem -J ubuntu@47.129.237.95 ubuntu@10.0.16.241` | ❌ Key absent from "Will attempt" list |

The same issue occurs with `-o IdentityFile=` — the option only reaches the final target.
You do NOT see this in normal operation because the bastion silently rejects default keys, so it just looks like "authentication failed."

### Lesson 2: Host keys for the internal server must be in LOCAL `known_hosts`

When you SSH manually (bastion → private host), the private host's host key goes into the **bastion's** `~/.ssh/known_hosts`.

With `-J`, your **local** SSH client performs the second authentication through the tunnel. It needs the private host's host key in your **local** `~/.ssh/known_hosts`, not the bastion's. If absent, you get:

```
Host key verification failed.
read_passphrase: can't open /dev/tty: No such device or address
```

The second line (`can't open /dev/tty`) is because there's no interactive terminal to prompt "do you want to add this key?".

**Fix**: Either:
- Add `StrictHostKeyChecking accept-new` to auto-accept on first connect, or
- Pre-populate the host key via `ssh-keyscan` through the bastion

### Lesson 3: SSH config beats `-J` for multi-hop connections

`-J` is a shorthand. For any non-trivial multi-hop setup (different users, different keys per hop, different options per hop), use `~/.ssh/config` with explicit `Host` blocks and `ProxyJump`. This gives you full control over which identity and options apply to each hop.

### Lesson 4: `type -1` in debug output is NOT an error

Seeing `debug1: identity file /path/to/key type -1` in verbose output does **not** mean the key failed to load. `type -1` means `KEY_UNSPEC` — the key has no associated certificate, which is normal for a bare PEM private key. The key works fine as demonstrated by the direct connection.

---

## Correct Solution: Use ~/.ssh/config

Create or append to `~/.ssh/config`:

```
Host bastion
    HostName <bastion-public-ip>
    User ubuntu
    IdentityFile /home/ubuntu/.ssh/libcloud-private-key.pem
    IdentitiesOnly yes

Host internal
    HostName <private-ip>
    User ubuntu
    IdentityFile /home/ubuntu/.ssh/libcloud-private-key.pem
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
    ProxyJump bastion
```

Then connect with:

```bash
ssh internal
```

### Why this works

- `Host bastion` block explicitly binds `IdentityFile` to the jump host — fixing Lesson 1
- `Host internal` block uses `ProxyJump bastion` — SSH correctly chains both hosts
- `StrictHostKeyChecking accept-new` — auto-accepts the private host's key on first connect, fixing Lesson 2
- `IdentitiesOnly yes` — ensures SSH only tries the specified key, not default keys

---

## Debugging Tips for Future SSH ProxyJump Issues

1. **Always use max verbosity**: `ssh -vvvvvvvvvvv` — the key diagnostic line is `Will attempt key: …`
2. **Grep for key presence**: `ssh -vvv … 2>&1 | grep "Will attempt key"` — if your key isn't listed, it's not being offered
3. **Test each hop individually first**: Verify the key works for direct connections to each host
4. **Check `type -1` isn't a red herring**: It just means no certificate, not a load failure
5. **Compare direct vs ProxyJump debug output**: The difference in "Will attempt key" lines reveals whether the identity is reaching the jump host
6. **`IdentitiesOnly yes`** is essential for isolating which key is being used during debugging


Resume this session with:
claude --resume 665964f9-4cb2-4110-9a79-b0d860258ba8

