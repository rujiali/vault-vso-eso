# ESO vs VSO — demo run sheet

About 30 minutes, plus questions. The story: **same Vault, same policies, same app, two operators.**
Anything that differs on screen is down to the operator.

## Before the client arrives

- [ ] `./scripts/up.sh` at least **20 minutes before** you start. The database and PKI scenarios need time for credentials to renew and certificates to roll, so the lab needs a history.
- [ ] Browser: http://localhost:8080 (dashboard) on the projector. Optional second tab: http://localhost:8200/ui, namespace `demo`.
- [ ] Terminal 1: `demo/leases.sh` (it keeps refreshing). Terminal 2: for commands.
- [ ] `./scripts/status.sh` shows every VaultStaticSecret, VaultDynamicSecret, VaultPKISecret and ExternalSecret as synced/ready.
- [ ] You rehearsed scenarios 1 and 6 on **the ESO version this lab installed** (`helm list -A`) and know how they come out. See "Things to verify" at the bottom.
- [ ] Zoom the browser to 125–150%.

---

## 0. Set the scene (2 min)

Show the dashboard. Two columns, two namespaces, one Vault Enterprise namespace (`demo`), and one Postgres. The two apps are identical: each reads its secrets once at start-up (from env vars and a certificate file), which is how most real applications behave.

Point out that the Vault policies are identical apart from one capability, `subscribe`, which lets VSO receive change events (open `terraform/policies.tf`). ESO is configured with sensible refresh intervals, not handicapped: KV every 1m (ESO's default is 1h), DB every 5m against a 10m TTL, and TLS every 3m against a 5m certificate.

## 1. First sync of a KV secret (2 min)

Row 1 shows both columns **in sync**.

> "Getting a KV secret into the cluster on day one, both operators do the job. The difference shows up when the secret changes in Vault, which is next."

Only the first sync is equal. Don't call KV "parity" overall: rotation (scenario 2) is where they diverge.

This concession is deliberate. It buys you credibility for everything that follows.

## 2. Rotation latency: events vs polling (4 min)

```bash
demo/rotate-kv.sh
```

Watch row 1.

- **VSO:** Vault publishes a KV change event and VSO syncs within about a second. VSO then rolls the Deployment, and the note shows how long it took for the app to be running on the new value.
- **ESO:** the Secret updates on the next poll, somewhere up to 60s away. Then the badge turns amber (**app on old value**) and stays amber, because nothing restarts the app.

Talking points:
- Polling is a trade-off between latency and load. Every ExternalSecret polls Vault on its interval, whether anything has changed or not. Multiply that by thousands of secrets across clusters. Events cost nothing until something actually changes.
- For an incident ("we've rotated a compromised credential"), the question is how long until **every workload** is running on the new value, not just how long until the Secret object changes.

## 3. App restart built in (2 min)

This is still on screen from scenario 2, so just name it:

> "The Kubernetes Secret changing isn't the finish line. The process has to pick it up. VSO has `rolloutRestartTargets`. With ESO you add a reloader."

Optional fair-fight step: `demo/eso-reloader.sh`, then `demo/rotate-kv.sh` again. The ESO app now restarts too, but only after its poll, and with a third-party component in the path to accredit, patch and trust. `demo/eso-reloader.sh remove` puts it back.

## 4. Dynamic database credentials: who owns the lease? (7 min) ← the main event

Switch to terminal 1 (`demo/leases.sh`).

- **VSO:** one lease and one Postgres user. VSO renews the lease at 67% of the TTL (the "valid until" time moves forward) and rotates it at max TTL.
- **ESO:** the generator mints a brand-new credential on every refresh and nothing renews the old ones. You'll see several live users, each waiting to expire. Meanwhile the ESO app is still using the username it started with.

Then switch to the dashboard, row 2. Each app tries to log in to Postgres with the credential it started with, every 10 seconds, and the dashboard shows the result:

- **VSO:** "Login OK" the whole time. Renewals keep the same credential valid, and when VSO finally rotates it, it restarts the app onto the new one.
- **ESO:** about 10 minutes after the app started, Vault expires its credential and the row turns red: **"app can't log in to Postgres"** with Postgres's own error. If the lab has been up for 20 minutes, it will already be red when you get here.

> "This is what a stale credential looks like in production: the Secret has a valid credential in it, but the running app is holding one the database no longer accepts."

Optional live moment: `kubectl --context kind-eso-vso -n app-eso rollout restart deploy/app`. The ESO app comes back green on the latest credential, then goes red again about 10 minutes later. Restarting only resets the clock.

Now delete both:

```bash
demo/delete-db.sh vso
demo/delete-db.sh eso
```

- **VSO:** revokes the lease straight away. The Postgres user is gone within seconds, and the Vault lease count drops to 0.
- **ESO:** the credentials stay live in Postgres until their TTL expires. Nobody in Kubernetes knows they exist any more.

Point at the dashboard's **Live users in Postgres** row, read straight from the database. VSO goes to 0, green "none left: revoked". ESO still lists its users with their countdowns, red "still valid, nothing tracking them".

> "Your security team's question is: when a workload is decommissioned, how long do its database credentials stay live? With VSO the answer is 'zero'. With ESO it's 'up to the TTL, and nobody's tracking them'."

`demo/restore.sh` to put things back.

## 5. TLS certificates (4 min)

Row 3. The certificates last 5 minutes.

- **VSO:** renews 2 minutes before expiry, rolls the app and revokes the old certificate. The serial number changes by itself and stays in sync.
- **ESO:** the Secret gets a new certificate every 3 minutes, but the app keeps serving the one it loaded at start-up. Wait for the red badge **app serving an expired cert**.

> "Short-lived certificates are where the ISM is heading. They only work if renewal and reload are automatic."

## 6. Resilience: kill the operator (3 min)

```bash
demo/kill-vso.sh
```

The script kills the VSO controller. It comes back up, reads its encrypted client cache (encrypted by Vault Transit) and resumes the **same** lease. The script prints the before and after credential: same username, no new Postgres user.

> "VSO owns lease state, so it has to survive restarts. It persists that state to Kubernetes encrypted with Vault Transit. This is what makes it safe in production, not just in a lab."

## 7. Tampering (2 min, optional)

```bash
demo/tamper.sh vso
demo/tamper.sh eso
```

Someone with `kubectl` overwrites a synced Secret. **Only present this as a difference if your rehearsal showed one.** If both operators restore it quickly, say so: that's parity.

## 8. Close (2 min)

- **Where ESO is the right call:** many secret backends through one API, pushing secrets back to a store (PushSecret), or a team that already runs it happily.
- **Where VSO earns its place:** Vault is the system of record, you use dynamic credentials or PKI, rotation speed matters, and you need it under the same vendor support contract as Vault Enterprise.
- **Both can coexist:** VSO for Vault, ESO for everything else. Say this if they already run ESO.

---

## If something goes wrong

| Symptom | Fix |
|---|---|
| Dashboard blank or "Kubernetes API" error | `kubectl --context kind-eso-vso -n demo-ui rollout restart deploy/dashboard` |
| Everything stopped after the Mac slept | `podman machine start`, then `scripts/unseal.sh` |
| One side not syncing | `scripts/status.sh`, then `kubectl -n app-eso describe externalsecret <name>` or `kubectl -n app-vso describe vaultstaticsecret app-config` |
| Scenario left things broken | `demo/restore.sh` |
| Out of time | Do scenarios 2 and 4 only. They carry the argument. |

## Things to verify in rehearsal

These are where the lab's behaviour depends on versions, so check them rather than trust the script:

1. **ESO lease cleanup.** Recent ESO releases added clean-up for some generated secrets (GeneratorState). Check whether the version you installed revokes Vault leases when an ExternalSecret is deleted or refreshed. If it does, scenario 4's "orphaned credentials" point weakens, so lead with the renewal and in-use-credential points instead.
2. **Tampering.** See scenario 7.
3. **VSO instant updates.** Run `demo/check-events.sh` first: it confirms Vault delivers KV change events to a token with VSO's policy. Then `demo/rotate-kv.sh` should reach VSO within about 2s. If VSO lags, the dashboard shows "Secret not updated yet" on its side.
4. **Instant updates for dynamic secrets (VSO 1.6).** Not wired into this lab. It's a good stretch goal if the client uses database static roles.
