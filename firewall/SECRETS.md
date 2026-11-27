# Store the DDNS and email secrets on the firewall

Two jobs on the firewall need a secret. `wan-event` updates a DDNS name when the WAN address changes: it needs
the provider's update URL, which carries a token. `fw-mail` sends the daily report and the alerts: it needs a
Gmail app password. Both are optional. The token for the daily brief is a third secret; see
[../agent/README.md](../agent/README.md).

## Where the secrets go

| Secret | Place on the firewall | Written by |
|---|---|---|
| DDNS update URL, login and name | `/etc/wan-event/ddns.curl` and `ddns.name`, root only (mode 0600) | `tools/store-wan-secrets.ps1` |
| Sender, recipient and app password | `/etc/credstore.encrypted/fw-mail`, encrypted with the box's TPM chip | `tools/store-mail-secret.ps1` |

- Each script reads the secret from a hidden prompt and sends it over SSH. It saves nothing on the admin PC.
- Do not put a secret into a file on the admin PC, into this repository, or into the chat with the agent.
- You can tell the agent the DDNS host name and the two email addresses. They are not secrets.
- The agent never reads the secrets. It checks only the file names, the file modes and the log.
- etckeeper does not record `/etc/wan-event/`. `deploy.sh` and the script add it to `/etc/.gitignore`.
- The backup that the admin PC pulls holds neither place.

## Part 1: Get a DDNS update URL

Any provider that takes an update as one HTTPS request works. The script shows the URL forms of three
providers. This example uses dynv6:

1. Open https://dynv6.com in a browser. Make an account and sign in.
2. Create a zone. Use a name that does not identify you, for example `name.dynv6.net`.
3. Open the account menu. Open **Keys**. Copy the token from **HTTP Tokens**.
4. Make the update URL. Put your zone and your token into this text:

   `https://ipv4.dynv6.com/api/update?zone=name.dynv6.net&token=<token>&ipv4=auto`

5. Keep the URL in your password manager. Do not save it in a text file.

## Part 2: Get a Gmail app password

1. Use the Google account that sends the mail. This account must have 2-Step Verification on.
2. Open https://myaccount.google.com/apppasswords.
3. Type the name `firewall`. Click **Create**. Use this password for nothing else.
4. Google shows a password of 16 letters in four groups. Keep this window open.
5. Type or paste the password when the script asks for it. The script removes the spaces.

Google removes all app passwords when you change the account password. If this occurs, do Part 2 and Part 3
again.

## Part 3: Run the scripts

`<address>` is the firewall's present address. Before you start, make sure that the SSH key works:

```powershell
ssh -i $HOME\.ssh\firewall_ed25519 fwadmin@<address> true
```

The command must show no error. The scripts use SSH without prompts, so a key with a passphrase must be loaded
in the SSH agent first (see [../agent/README.md](../agent/README.md)).

Procedure:

1. Open Windows PowerShell on the admin PC, in the repository folder. You do not need Administrator rights.
2. For the email, run:

   ```powershell
   powershell -ExecutionPolicy Bypass -File firewall\tools\store-mail-secret.ps1 -Target <address>
   ```

   It asks for the sender address, the recipient address and the app password (hidden). It stores them as one
   encrypted credential and sends a test email.
3. For the DDNS, run:

   ```powershell
   powershell -ExecutionPolicy Bypass -File firewall\tools\store-wan-secrets.ps1 -Target <address>
   ```

   Give these values at the prompts:

   | Prompt | Value |
   |--------|-------|
   | DDNS host name | `name.dynv6.net` |
   | Provider update URL (hidden) | The URL from Part 1, step 4 |
   | Provider login | Press Enter (dynv6 does not use a login; deSEC does) |

4. Read the output. Each file shows one line `stored /etc/wan-event/<file>`.
5. Read the last lines:
   - If `deploy.sh` installed a profile, the script runs `wan-event TEST`. You get a test email if the email
     credential is stored.
   - If `deploy.sh` did not run yet, the script says so. The values are stored. Test after the first deploy:
     `sudo wan-event TEST` on the box.
6. Tell the agent "secrets stored". The agent then checks the log with `journalctl -t wan-ip-watch`.

To skip the DDNS part, press Enter at its first prompt. The script then keeps the files that are there.

Without `-Target`, both scripts use `192.168.50.1`, the example house's firewall address.

## Part 4: Change or remove a secret

- To change a secret, run its script again. It replaces what is stored.
- To stop the email, run `ssh -i $HOME\.ssh\firewall_ed25519 fwadmin@<address> "sudo rm /etc/credstore.encrypted/fw-mail"`.
  Then delete the app password in the Google account.
- To stop the DDNS update, run `ssh -i $HOME\.ssh\firewall_ed25519 fwadmin@<address> "sudo rm /etc/wan-event/ddns.curl /etc/wan-event/ddns.name"`.
  Then delete the token at the provider.

## After the DDNS name works

1. Use the name wherever something outside the house must find it. With the example forward, that is the ID
   server and the relay server setting of the remote RustDesk client, and the `-r` argument of your own
   RustDesk server.
2. If the old router or a PC ran its own DDNS update or WAN address watch, turn that off after the cutover, when
   the firewall's test email has arrived.
