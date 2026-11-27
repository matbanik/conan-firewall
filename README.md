<p align="center">
  <img src="docs/images/readme/conan.png" width="140" alt="Conan, the conan-firewall guard dog: a pixel-art Belgian Malinois in a tan working harness in front of a brick wall topped with flames, with a glowing shield in the night sky">
</p>

<h1 align="center">conan-firewall</h1>

<p align="center">
  <b>A home firewall that an AI agent sets up and runs with you.</b><br>
  Plain Debian 13 and text files in git. No appliance, no web interface, no settings page.<br>
  Named after Conan, the Belgian Malinois military working dog. He guards the wall.
</p>

## The pain

- **Your router is a sealed box.** Ask it which device talked to which server last night, and it has no answer.
- **The vendor decides when the security fixes stop.** That is often years before the hardware wears out.
- **Every change is a click.** It leaves no record, nobody reviews it, and there is no undo.
- **Firewall products are heavy.** pfSense and OPNsense are whole appliances. You learn a web interface with
  hundreds of settings, and that interface is made for a person who clicks, not for an agent that reads files.

## The idea: plain Debian, managed by an agent

| | A firewall product | conan-firewall |
|---|---|---|
| Base | Its own FreeBSD-based system | Stock Debian 13 and its standard tools: nftables, dnsmasq, unbound, Suricata |
| Managed by | A person in a web interface | An AI agent, or you, over SSH |
| Configuration | One file that the web interface writes | Small text files in git that you can read, compare and put back |
| Web interface | Yes, and you must protect it | None. One thing less to attack |
| Security fixes | The product's releases | Debian's own, installed automatically |

Only what a home router needs is installed, and each part is the same program that runs on Debian servers
everywhere. An agent already knows these tools. It can read every file, check a change before it goes in,
and put the old state back when something breaks. More in [docs/design-decisions.md](docs/design-decisions.md).

## Start here

Open the repository with an AI coding agent and say:

> Read AGENTS.md and guide me through the setup.

| Stage | What the agent does with you | Read more |
|---|---|---|
| 1. Configure | Interviews you and writes your answers to one small file | [SETUP-QUESTIONS.md](SETUP-QUESTIONS.md) |
| 2. Build and install | Builds the installer from the stock Debian ISO and checks every download | [BUILD.md](installer/BUILD.md), [INSTALL.md](installer/INSTALL.md) |
| 3. Connect | Reaches the box over SSH, with the limits you choose | [agent/README.md](agent/README.md) |
| 4. Start the services | Deploys a test profile and checks each service | [firewall/README.md](firewall/README.md), [SERVICES.md](firewall/SERVICES.md) |
| 5. Cut over | Plans the swap with you: about 30 minutes, with a way back | [CUTOVER.md](firewall/CUTOVER.md) |

Nothing changes on your network before stage 5. Without an agent, follow [SETUP-GUIDE.md](SETUP-GUIDE.md):
every step is a command you can type.

## What you get

- **A strict firewall.** Everything is closed unless you open it. No UPnP. Known bad addresses are blocked, and
  the lists update every 6 hours.
- **DNS that blocks ads, trackers and malware** for every device in the house, with encrypted lookups.
- **Answers about your own network.** Traffic per device, intrusion detection and every log go into a database
  on the box.
- **A daily brief by email, in plain words.** An agent with read-only access to the logs writes it.
  See a [brief](site/example/samples/brief-sample.txt) and a [report](site/example/samples/report-sample.md).
- **Changes you can take back.** Every file is checked before it is installed. If you do not confirm a deploy
  within 15 minutes, the box puts the old files back.
- **Little upkeep.** Security updates install by themselves, your PC pulls the backups, and no secret ever
  enters the repository.

**[The full feature list](docs/features.md)**

## What you need

A small PC with three Ethernet ports (tested on a Lenovo ThinkCentre M920q), a PC to manage it from, a switch,
an access point, and an evening. Details: [docs/before-you-start.md](docs/before-you-start.md).

## Know before you start

- **It ships no image, ISO, binary or key.** You or your agent build the installer from stock Debian.
- **It is one house's real configuration with example values, not a product.** Expect to read files.
- **Make it yours.** The example is one house: a single IPv4 LAN. VLANs, a VPN server, IPv6 and PPPoE are
  not set up in it, and nothing blocks them. It is stock Debian, so tell your agent what you need and it
  builds and tests it. See [what the example leaves out](docs/features.md#not-in-the-example).

## More

[Setup guide](SETUP-GUIDE.md) ·
[Questionnaire](SETUP-QUESTIONS.md) ·
[Features](docs/features.md) ·
[Before you start](docs/before-you-start.md) ·
[Design decisions](docs/design-decisions.md) ·
[Agent rules](AGENTS.md) ·
[Security](SECURITY.md) ·
[MIT license](LICENSE)
