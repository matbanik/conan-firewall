# Security

## What this repository is

A worked example of a home router and firewall on Debian, built by one person with AI help for one house. It
is not a product. Nobody audits it, and there are no releases with security support. Read the rule set and the
programs before you put the box between your house and the internet; they are short on purpose.

## What it protects against, and what not

| It does | It does not |
|---|---|
| Drop everything from the internet that was not asked for | Protect a device from what its own user starts |
| Block known bad names and addresses for every device | Decrypt or inspect HTTPS |
| Detect known attack patterns (Suricata) and report them | Block on detection (IDS, not IPS) |
| Record who talked to whom, and flag tunnels and remote-access tools | Separate devices from each other: the LAN is flat |
| Undo a bad change by itself | Protect against someone with physical access to the box |
| Keep itself patched | Handle IPv6. It is off |

## Secrets

No secret belongs in this repository or in your fork of it:

- `site/<name>/` and `out/` are ignored by git. Your addresses stay on your PC.
- The DDNS token, the mail password and the Claude token reach the box only through the `store-*.ps1`
  scripts, typed by a person. They are in no backup.
- `tools/scan-public.py` checks the tracked files for addresses, MAC addresses, mail addresses and key
  formats that are not example values. `sh tools/hooks/install.sh` makes it a pre-commit hook.
- `firewall/validate.sh` fails when a file in the tree looks like it holds a credential.

If you publish a fork, run the scan first. The example values to use are in `AGENTS.md`.

## An AI agent with root on your router

The setup lets an AI agent run commands as `fwadmin`, which has sudo without a password by default. That is a
real risk and a choice. `agent/README.md` says what limits it and how to switch to password sudo. The rules
the agent follows are in `AGENTS.md`; they are instructions, not locks.

Text that arrives from the network (DNS names, host names, log lines) ends up in the report and in front of
the model that writes the brief. That session has no network tools, no sudo and one read-only database tool,
and its prompt says to treat such text as data. Do not give it more tools.

## Reporting a problem

Open an issue in this repository. For a problem that would put other users at risk if it were public, use
GitHub's private vulnerability report on the repository's Security page instead. Do not put your own
addresses, logs or secrets in an issue.

There is no promise of a fix or a schedule. This is a personal project.
