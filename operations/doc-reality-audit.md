# Documentation-vs-Reality Audits

Documentation drifts from the system it describes. A **doc-reality audit** treats
every documented claim as a hypothesis and checks it against live state with a
concrete verification command - the same root-cause discipline used for
incidents, applied at documentation scale. Run against a homelab repo (2026-07-08)
it surfaced ~30 drifts, several of them real functional bugs hiding behind
correct-looking docs.

## The core move: a claim is not a fact

A line in a doc ("VM100 boots at order 2", "paperless is pinned to a fixed tag",
"managed by the homelab-schedule role") is an *assertion about the world*. Until
you run the command that reads the world, you don't know if it's true. The audit
loop per claim:

1. **Read the claim** in the doc.
2. **Name the verification command** that reads the corresponding live state.
3. **Run it, compare.**
4. **Reconcile** - and consciously decide the *direction* (see below).

This is deliberately the same shape as symptom -> verification command ->
diagnosis -> fix. The only difference is the trigger is a written claim rather
than an alert.

## Reconciliation direction is a decision, not a default

When doc and reality disagree, "fix the doc to match reality" is the common case
but **not automatic**. Three outcomes, and choosing between them needs intent:

| Disagreement | Correct direction | Example from the audit |
|---|---|---|
| Doc stale, reality fine | Fix the **doc** | Boot order, image versions, node naming (`CT260`->`lxc260`) |
| Doc right, reality wrong | Fix the **reality** (or file it) | sshd effectively unhardened - reality is the bug |
| Doc "wrong", reality intentional | Fix the **doc**, record the rationale | Calibre-Web on `tier1` not `tier2` - confirmed deliberate |

The dangerous instinct is to "make the red go away" by editing the doc every
time. That silently launders a real defect into "documented behaviour". Deciding
direction requires knowing what was *intended* - which is exactly why an audit
often ends in a question to a human, not a commit.

## Drift classes worth grepping for

Categories that recur, each with the live-state command that adjudicates it:

- **Monitoring targets.** Docs list N scrape jobs; live config lists more/fewer.
  Verify against the actual `prometheus.yml`, not the prose. (Found: documented 13
  jobs, live 14 jobs / 19 targets.)
- **Image pins.** Docs/compose say a service is pinned; the *running container*
  says otherwise. `docker inspect <ctr>` for the live image ref - the repo file is
  only a claim until it's actually deployed (see the compose-sync gap in
  [Docker Compose Updates](../ansible/docker-compose-updates.md#the-sync-gap-a-role-that-updated-nothing-2026-07-08)).
- **Boot / dependency order.** Prose tables rot fast. Rebuild from `pct config` /
  `qm config`, don't trust the narrative.
- **"Managed by <tool>" claims.** The highest-value lie. A doc saying a script is
  Ansible-managed when it was hand-deployed means it silently vanishes on rebuild.
  Verify the role actually exists *and* has been applied.
- **Access-control policy.** The mirrored policy doc vs the live ACL. A changelog
  entry claiming a rule was added is not proof the rule's *body* was updated -
  check the actual policy object.
- **Naming consistency.** A renamed entity leaves stale tokens scattered
  (`CT260`/`ct260` vs `lxc260`). `grep -rn` the old token repo-wide.

## "Green and correct-looking" is the failure mode

The audit's most useful lesson: the bugs that survive are the ones where every
surface looks right.

- The repo showed a pinned image - but the pin was never shipped to the node.
- `--check` reported `changed=0` on the ssh role - but the node was unhardened
  because a higher-priority drop-in won.
- A health-check playbook exited 0 - but matched zero hosts and wrote no report.

None of these throw an error. Each requires reading the *effective* state
(`sshd -T`, the running container, the produced artifact), not the input you
believe you supplied. **Trust the output of the system, not the intent of the
config.**

## Public-repo hygiene: facts, not exploit detail

For a portfolio/public repo, when an audit finds a live security gap that is
**not yet fixed**, document the *fact* (what is misconfigured, that it's tracked)
without a reproducible exploit recipe. Precedent from this audit: a
tier-misassignment and an unhardened-sshd finding were recorded as tracked tech
debt with enough to act on, but no step-by-step "here is how to walk through the
open hole" while live remediation was still pending. Documenting reality honestly
and handing an attacker a runbook are different things.

## Related

- [Runbook Methodology](runbook-methodology.md) - the root-cause loop this reuses
- [Repo Validation](repo-validation.md) - structural checks that catch a subset mechanically
- [Docker Compose Updates](../ansible/docker-compose-updates.md) - the compose-sync drift in full
- [SSH Hardening](../ansible/ssh-hardening.md) - the sshd first-match-wins drift in full
