# Before you start

What you need, how your own values stay apart from the shared files, and where things are in the repository.

## What you need

| Need | Detail |
|---|---|
| The firewall machine | A small x86-64 PC with at least three Ethernet ports: internet, LAN, and the rescue port. Tested on one machine only: a Lenovo ThinkCentre M920q with a four-port Intel i350 card. Other hardware needs the changes in [../installer/BUILD.md](../installer/BUILD.md), "Other hardware" |
| Disk and memory | The log database may grow to 100 GB (the limit is a setting). 8 GB of memory or more for Suricata and the report |
| A TPM 2.0 chip | Only for the stored mail password |
| An admin PC | It builds the image (Linux, or WSL on Windows), holds the SSH key, and pulls the backups. The helper scripts in `firewall/tools/*.ps1` are written for Windows PowerShell and are untested elsewhere |
| A switch and an access point | The firewall has no Wi-Fi. Your old router can become the access point |
| An internet line | The example gets its address by DHCP. For PPPoE or a fixed address your agent writes the `wan0` part ([features.md](features.md#not-in-the-example)) |
| Time | An evening for stages 1 to 4, and 30 minutes without internet for the cutover |

## What is a setting and what is an edit

`site/<name>/site.env` holds the values that differ in every house: the LAN prefix, MAC addresses, host names,
the time zone, the install disk. `site/<name>/files/` holds whole files that are yours alone, such as the DHCP
reservations. `python3 tools/render-site.py site/<name>` writes a filled-in copy to `out/<name>/`, and that
copy is what you build and deploy. `site/<name>/` and `out/` are ignored by git, so your values stay on your
PC.

Everything else is a file that you edit: the rule set, the block list sources, the report queries, the text
that tells the brief what is normal in your house. This is a real configuration, not a product with a settings
page. The comments in the files still name the original setup (a fiber line, a consumer router as the access
point, a RustDesk server). Read them as the worked example they are.
[../SETUP-QUESTIONS.md](../SETUP-QUESTIONS.md) names the file for each choice.

## Repository layout

| Path | What |
|---|---|
| `AGENTS.md`, `CLAUDE.md` | Entry point for an AI agent |
| `SETUP-QUESTIONS.md`, `SETUP-GUIDE.md` | The questionnaire and the step-by-step guide |
| `installer/` | Scripts that build and verify the installer image, and the install walkthrough |
| `agent/` | How an agent connects to the box, and what it may do there |
| `firewall/` | The configuration, laid out as on the box, with `validate.sh` and `deploy.sh` |
| `firewall/tools/` | Scripts for the admin PC: backups, secrets, the cutover |
| `site/example/` | An example site and synthetic sample outputs |
| `tools/` | `render-site.py`, `scan-public.py`, the pre-commit hook |
| `docs/` | The full feature list, why each design choice was made, and this page |

## Security

Never commit your `site/<name>/` folder, a key or a token. Install the pre-commit hook once:
`sh tools/hooks/install.sh`. More in [../SECURITY.md](../SECURITY.md).

## License

MIT. See [../LICENSE](../LICENSE). The block lists, rule sets and programs that the box downloads have their
own licenses and terms.
