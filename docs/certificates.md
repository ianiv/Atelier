# Certificates for HTTPS

Atelier's MCP server (Settings ▸ Agents) can serve agents on other devices over HTTPS, so the token and the images they send and get are encrypted on the way. This page covers getting a certificate for it, and making each agent trust it. For the server itself, see [Atelier for agents (MCP)](../MCP.md); for what the settings do, see [HTTPS](../MCP.md#https) there.

HTTPS only matters once **Access** is **Local network**. With **This Mac only** (the default), nothing leaves the Mac and you need no certificate.

## Before you turn on Local network

Open the server to other computers only on a network you trust: your own home network, with devices you control. Coffee-shop, hotel, office and school Wi-Fi, guest networks and the shared network of an apartment building are not that: you don't know who else is on them.

Anyone who can reach the server can do what an agent does: generate images and videos with your models and your GPU, read and change the Create screen, and see images in the current project. They can't read or write files on this Mac: file paths from other devices are refused.

- **The token** is what keeps other people on the network out. Without it, anyone on the network can use the server. Keep **Require Token** on.
- **HTTPS** keeps the token secret. Without it, the token and every image cross the network in plain text, and anyone on the same Wi-Fi can read them, then use the token themselves.

So:

- The safest setting is **This Mac only**.
- On a network you don't fully trust, use HTTPS (a Tailscale certificate or an imported one) **and** the token, or don't turn on Local network at all.
- Turn the server off, or set Access back to This Mac only, when you're not using it from another device.
- If the token may have leaked (pasted somewhere, sent in plain HTTP on a network you don't trust), click **Regenerate** and update your agents.

Atelier is free software provided without any warranty (GPL-3.0, sections 15 and 16, in [LICENSE](../LICENSE)). You're responsible for how you expose it on your network. If you're not comfortable with that, leave Access on This Mac only.

## Choosing a certificate

Settings ▸ Agents ▸ Encryption ▸ **HTTPS** offers two:

| | Tailscale certificate | Imported certificate |
| --- | --- | --- |
| Clients reach | `https://<name>.<tailnet>.ts.net/mcp` (port 443 of your tailnet) | `https://<host>:7864/mcp` (the HTTPS Port) on your local network, and over Tailscale by address |
| Clients need | to be on your tailnet | to reach the Mac, and to trust your certificate |
| Trust on clients | none to set up: it's from Let's Encrypt | your CA added to each client, unless it's from a public CA |
| Renewal | automatic | you import a new one before it expires |
| Name is public | yes, in Certificate Transparency logs | no (a private CA) |

Pick **Tailscale certificate** if your devices already use Tailscale: there's nothing to make and nothing for clients to trust. Pick **Imported certificate** for devices on the same local network without Tailscale, or if you don't want your tailnet's name published.

## Tailscale certificate

Atelier's own Tailscale node gets a certificate for its tailnet name and serves HTTPS on your tailnet's port 443.

1. In the [DNS page of the Tailscale admin console](https://login.tailscale.com/admin/dns), turn on **MagicDNS**, then under **HTTPS Certificates** choose **Enable HTTPS**. Settings ▸ Agents ▸ Encryption has a **Turn On HTTPS Certificates for Your Tailnet** link to that page.
2. In Settings ▸ Compute ▸ Tailscale, choose **Sign In…** and sign in in your browser, until Settings shows **Signed in as** you. See [Tailscale, without the Tailscale app](remote.md#tailscale-without-the-tailscale-app).
3. In Settings ▸ Agents, set **Access** to **Local network**, then **Encryption ▸ HTTPS** to **Tailscale certificate**.
4. Encryption's **Status** shows **Getting the certificate from Tailscale…** (the first time can take a minute), then **Listening at https://<name>.<tailnet>.ts.net/mcp**. **Certificate** shows its name and expiry, and **SHA-256** its fingerprint.
5. In **Connect an Agent**, pick that address under **Address** and copy the setup to the other device. That device has to be on your tailnet (the Tailscale app, or Atelier signed in there).

The certificate lasts 90 days. Atelier asks Tailscale for it each day, and Tailscale issues a new one once less than 14 days are left. **Renew** asks now; it gets a new certificate only within those 14 days, and otherwise the same one. Status warns in orange if a renewal failed or the certificate has under 14 days left (which means renewals are failing).

The certificate comes from Let's Encrypt, which lists every certificate it issues in public [Certificate Transparency](https://certificate.transparency.dev) logs. Your tailnet's name (`<tailnet>.ts.net`) and this device's name on it become public. Nobody can reach the device from that name alone, but don't pick a device name you'd mind being seen.

**Limit access to your Tailscale account** (Settings ▸ Compute, on by default) applies here too: only devices signed in to the same Tailscale account get through, which matters if you've shared this device with someone else's tailnet.

### If it doesn't work

What Encryption's Status says:

| Status | What to do |
| --- | --- |
| Sign in to Tailscale in Settings ▸ Compute. | Atelier's own node isn't signed in. Sign in there; the Tailscale app doesn't count. |
| This device has no tailnet name yet. Turn on MagicDNS for your tailnet. | Turn on MagicDNS in the admin console's DNS page. |
| Tailscale's own message, often about HTTPS certificates not being turned on | Turn on HTTPS Certificates in the DNS page, then choose **Renew** or switch HTTPS off and on. |
| Port 443 on the tailnet is already used by Compute. | Compute is serving on 443; give it another port in Settings ▸ Compute, then **Try Again**. |
| Couldn't listen on the tailnet's port 443. | Click **Try Again**. |
| This build doesn't include Tailscale. | A build from source without Tailscale: see [Getting started](getting-started.md#tailscale-in-your-own-build), or use an imported certificate. |
| Renewing the certificate failed: … | The current certificate keeps working until it expires. Fix what the message says, then **Renew**. |

## Imported certificate

You give Atelier a `.p12` file (PKCS #12): the certificate, its private key, and any intermediate certificates, protected by a password. Atelier serves it on the **HTTPS Port** on every interface, `https://<host>:7864/mcp` unless you change it.

### What the certificate needs

- **Names (Subject Alternative Names)** for every way clients type the Mac's address. Clients ignore the Common Name. Include the Mac's `.local` name, its local network address, and, if agents connect over the Tailscale app by address, its Tailscale address (100.x.y.z). Adding `localhost` and `127.0.0.1` lets you test on the Mac itself. Connect an Agent's **Address** lists the addresses Atelier offers.
- **Extended Key Usage: serverAuth** (TLS Web Server Authentication).
- **Lifetime**: at most 825 days for a certificate from your own CA, which is what Apple's systems accept; 397 days is a safe choice, and what the recipes below use. Public CAs issue for less (398 days or shorter).
- **The chain**: if your CA has an intermediate certificate, put it in the `.p12` after the certificate. Atelier sends what the file carries; without the intermediate, clients fail with errors like `unable to get local issuer certificate`.
- **Key**: RSA (2048 bits or more) or ECDSA P-256 both work.
- **Encryption of the `.p12`**: what OpenSSL 3 and later make by default (AES-256 with PBKDF2) imports on the macOS versions Atelier runs on, as do older `-legacy` files and files from macOS's built-in `openssl` (LibreSSL). You don't need `-legacy`.

Your local network address can change when your router hands out a new one. Reserve it for the Mac in the router's DHCP settings, or use the `.local` name, or the certificate will need making again.

### Find the Mac's names

- **`.local` name**: System Settings ▸ General ▸ Sharing, under **Local hostname** (click **Edit…** to see or change it). Or in Terminal:

  ```bash
  echo "$(scutil --get LocalHostName).local"
  ```

  Names aren't case sensitive; the recipes use lowercase.
- **Local network address**: System Settings ▸ Wi-Fi (or Network ▸ Ethernet) ▸ **Details…**, or:

  ```bash
  ipconfig getifaddr en0    # Wi-Fi on most Macs; try en1 for Ethernet
  ```

The recipes below use `studio-mac.local` and `192.168.1.20`; put in yours.

### Recipe A: mkcert

[mkcert](https://github.com/FiloSottile/mkcert) makes a small CA of your own and certificates from it, and adds the CA to this Mac's trust settings.

```bash
brew install mkcert
mkcert -install        # makes the CA, adds it to the System keychain (asks for your password)
mkcert -pkcs12 -p12-file atelier.p12 studio-mac.local 192.168.1.20 localhost 127.0.0.1
```

mkcert's `.p12` password is `changeit`. Its certificates last a little over two years, within the 825-day limit.

Other computers that run agents need to trust mkcert's CA. Find it with `mkcert -CAROOT`: the file is `rootCA.pem` in that folder. Copy **only `rootCA.pem`** to them and see [Make agents trust your CA](#make-agents-trust-your-ca). Never copy `rootCA-key.pem`: with it, anyone can make certificates your devices trust.

To make a `.p12` with a password of your own instead, make PEM files and bundle them with OpenSSL:

```bash
mkcert -cert-file atelier.crt -key-file atelier.key studio-mac.local 192.168.1.20 localhost 127.0.0.1
openssl pkcs12 -export -inkey atelier.key -in atelier.crt -name "Atelier MCP" -out atelier.p12
```

### Recipe B: OpenSSL with your own CA

A CA certificate you make once and trust on each client, and a server certificate signed by it. This works with Homebrew's OpenSSL and with the `openssl` that comes with macOS. Run it in a new, private folder:

```bash
mkdir -m 700 ~/AtelierCA && cd ~/AtelierCA
NAME=studio-mac.local
IP=192.168.1.20

# 1. The CA: a key and a certificate good for 10 years.
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out ca.key
chmod 600 ca.key
openssl req -x509 -new -key ca.key -sha256 -days 3650 -subj "/CN=Atelier Home CA" \
  -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" -out ca.crt

# 2. The server certificate's settings: its names and its use.
cat > atelier.ext <<EOF
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = serverAuth
subjectAltName = DNS:$NAME, IP:$IP, DNS:localhost, IP:127.0.0.1
EOF

# 3. Its key, a request, and the certificate the CA signs (397 days).
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out atelier.key
chmod 600 atelier.key
openssl req -new -key atelier.key -subj "/CN=$NAME" -out atelier.csr
openssl x509 -req -in atelier.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -days 397 -sha256 -extfile atelier.ext -out atelier.crt

# 4. Check it, then bundle it into a .p12 (it asks for a password).
openssl verify -CAfile ca.crt atelier.crt
openssl x509 -in atelier.crt -noout -subject -enddate -ext subjectAltName,extendedKeyUsage
openssl pkcs12 -export -inkey atelier.key -in atelier.crt -certfile ca.crt -name "Atelier MCP" -out atelier.p12
```

To add the Tailscale address, add `, IP:100.x.y.z` to `subjectAltName`. On macOS's built-in `openssl`, `-ext` in step 4 isn't there: use `openssl x509 -in atelier.crt -noout -text` instead.

`ca.crt` is what clients trust ([Make agents trust your CA](#make-agents-trust-your-ca)). `ca.key` signs certificates: keep it in this folder, and nowhere else. A new server certificate next year needs only steps 3 and 4.

### Recipe C: a certificate you already have

A certificate from your company's CA, or one you made elsewhere, usually comes as PEM files: the certificate, the intermediates (often in a "chain" or "fullchain" file), and the private key. Ask for one with the names and the serverAuth use listed under [What the certificate needs](#what-the-certificate-needs). Put the certificate first and the intermediates after it, then bundle them:

```bash
cat server.crt intermediate.crt > fullchain.pem     # skip if you already have a fullchain file
openssl pkcs12 -export -inkey server.key -in fullchain.pem -name "Atelier MCP" -out atelier.p12
```

If the key is encrypted, OpenSSL asks for its password first, then for the new `.p12`'s. Check the order with:

```bash
openssl pkcs12 -in atelier.p12 -nokeys | grep -E "subject|issuer"
```

The first `subject` should be the Mac's name, and each `issuer` the next one's `subject`.

If it already comes as a `.p12` or `.pfx`, import it as it is.

### Recipe D: `tailscale cert` from the Tailscale app

If your devices reach the Mac through the Tailscale app rather than Atelier's own sign-in, the app can get a Let's Encrypt certificate for the Mac's own tailnet name, which clients trust without any setup. Use this when you want HTTPS at the Mac's existing tailnet name on the HTTPS Port, for example because Atelier isn't signed in to Tailscale on that Mac. Otherwise the **Tailscale certificate** option is simpler: it renews itself.

The same admin console settings apply (MagicDNS and HTTPS Certificates on). With the Tailscale command line installed (on Mac, from the Tailscale app's settings):

```bash
tailscale status --json | grep -m1 DNSName       # the Mac's name, like studio-mac.tail1234.ts.net.
tailscale cert --cert-file atelier.crt --key-file atelier.key studio-mac.tail1234.ts.net
openssl pkcs12 -export -inkey atelier.key -in atelier.crt -name "Atelier MCP" -out atelier.p12
```

`atelier.crt` already holds the intermediate. The certificate names only the tailnet name, so clients must use `https://studio-mac.tail1234.ts.net:7864/mcp`, which is not one of the addresses Connect an Agent lists: type it into the setup yourself. It lasts 90 days and doesn't renew in Atelier: run the commands again and import the new file every two months or so. The name becomes public in Certificate Transparency logs, as with the Tailscale certificate.

### Import it

1. In Settings ▸ Agents, set **Access** to **Local network** and **Encryption ▸ HTTPS** to **Imported certificate**.
2. Click **Import…** beside **Certificate**, choose the `.p12`, and type its password.
3. Check **Certificate** (its name and expiry) and **SHA-256**. The fingerprint should match:

   ```bash
   openssl x509 -in atelier.crt -noout -fingerprint -sha256
   ```

4. Encryption's **Status** shows **Listening at https://192.168.1.20:7864/mcp** (or the port you typed in **HTTPS Port**). **Connect an Agent** now offers the `https://` addresses.

If the import fails, the alert says why: **The password is wrong.**, or **The file has no certificate with its private key.** (a `.p12` made without `-inkey`, or a certificate-only file). **Import a certificate to use HTTPS.** in Status means there's none yet.

The file and its password are kept in your Keychain. **Remove** forgets them. Delete the `.p12` and the server key from wherever you made them once imported, or keep them only in your private folder.

### Renewing

Status warns in orange two weeks before the certificate expires. Make a new one (for Recipe B, steps 3 and 4) and **Import…** it: it replaces the old one at once. Clients that trust your CA need nothing new. If you change the names (a new address, say), make a new certificate too.

## Make agents trust your CA

A certificate from your own CA (Recipe A or B) or a company CA is only trusted where that CA is. On each computer that runs an agent, copy the CA certificate (`ca.crt`, or mkcert's `rootCA.pem`) over and do what its agent needs. The Tailscale certificate and Recipe D need none of this.

**Add it to the Mac's System keychain** (many apps then trust it, including Safari and Apple's `curl`):

```bash
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ca.crt
```

Or double-click `ca.crt`, add it to the **System** keychain in Keychain Access, open it, and under **Trust** set **When using this certificate** to **Always Trust**. To undo, delete it there.

On **Windows**, from an administrator prompt: `certutil -addstore -f Root ca.crt`. On **Linux** (Debian, Ubuntu): `sudo cp ca.crt /usr/local/share/ca-certificates/atelier-ca.crt && sudo update-ca-certificates`; on Fedora, copy it to `/etc/pki/ca-trust/source/anchors/` and run `sudo update-ca-trust`.

**Claude Code, Gemini CLI, `mcp-remote` and other Node.js clients** don't use the system store by default. Point `NODE_EXTRA_CA_CERTS` at the CA file in the shell (or shell profile) they start from:

```bash
export NODE_EXTRA_CA_CERTS="$HOME/AtelierCA/ca.crt"
```

**Codex** is a Rust program and doesn't read `NODE_EXTRA_CA_CERTS`. Add the CA to the system store as above first. If Codex still refuses the certificate, check Codex's documentation for custom CA settings; many Rust TLS clients also read `SSL_CERT_FILE`, set to a file holding the system's CAs followed by yours. This hasn't been tested with Codex.

**Cursor and VS Code** use the system's certificates (on macOS, the keychain) for MCP servers: add the CA as above and restart the app. In VS Code, the **Http: System Certificates** setting must stay on (it is by default).

**curl**: `--cacert ca.crt`, as below.

The setup **Connect an Agent** shows for an `https://` address already carries the token; with Require Token on, it's an `Authorization: Bearer` header. Only the CA needs adding.

## Check it

From the computer that runs the agent, with the token from Settings (**Copy** beside Token):

```bash
curl --cacert ca.crt https://studio-mac.local:7864/mcp \
  -H "Authorization: Bearer <token>" -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"ping"}'
```

It answers `{"jsonrpc":"2.0","id":1,"result":{}}` (or similar). Leave out `--cacert` for the Tailscale certificate. What else you might see:

- `SSL certificate problem: unable to get local issuer certificate`: the CA isn't trusted here, or the `.p12` lacks the intermediate.
- `no alternative certificate subject name matches`: the address you typed isn't in the certificate's names.
- `401`: the token is missing or wrong.
- `Connection refused` or a timeout: Access isn't Local network, HTTPS is off, the port is different, or the Mac's firewall blocks Atelier.

To see the certificates the server sends, with the leaf first and then each intermediate:

```bash
openssl s_client -connect studio-mac.local:7864 -servername studio-mac.local -showcerts </dev/null
```

Add `-CAfile ca.crt` to have it check them: the last lines should say `Verify return code: 0 (ok)`.

## Keeping it safe

- **Keep the CA key private.** `ca.key` (or mkcert's `rootCA-key.pem`) can make certificates for any name, including websites, that your devices will trust. Keep it in a folder only you can read (`chmod 700` the folder, `chmod 600` the key), never copy it to other computers, and back it up somewhere private if you want to reuse the CA.
- **Use a real password for the `.p12`**, not an empty one, and don't keep the `.p12` and its password together.
- **If a key may have leaked**, make a new certificate and import it; if it was the CA key, make a new CA, remove the old one from every client (Keychain Access, or the store you added it to) and trust the new one.
- **The token is still needed.** HTTPS hides the token and the traffic; the token is what keeps others out. Keep Require Token on, and **Regenerate** it if it may have leaked.
