# Burp Collaborator Server with Docker and Let's Encrypt

Run a private Burp Collaborator Server in Docker with a Let's Encrypt certificate. One command performs first-time setup and starts the server; one command shuts it down.

## What you need

- A Linux server with a public IPv4 address
- Bash and a working Docker installation
- A domain or subdomain delegated to the server
- A Burp Suite JAR containing the Collaborator server
- Internet access to ports used by Collaborator

No host installation of Java, Certbot, `jq`, `openssl`, or `bc` is required.

## 1. Delegate a domain

Choose a dedicated domain such as `collab.example.com`. Create an address record for its nameserver and delegate the Collaborator domain to it:

```text
ns1.collab.example.com.  A   1.2.3.4
collab.example.com.      NS  ns1.collab.example.com.
```

Replace `1.2.3.4` with the server's public IPv4 address. If the nameserver is inside the delegated domain, your registrar or parent DNS provider may call the address record a glue record.

Confirm the delegation before starting setup:

```bash
dig NS collab.example.com
dig A ns1.collab.example.com
```

Both TCP and UDP port 53 must reach this server. DNS delegation is required because the setup uses Burp Collaborator's DNS server to complete the Let's Encrypt DNS-01 challenge.

See [PortSwigger's DNS configuration documentation](https://portswigger.net/burp/documentation/collaborator/deploying#dns-configuration) for additional background.

## 2. Start Collaborator

Clone the repository, enter it, and run the wizard:

```bash
git clone https://github.com/intrudir/burpcollaborator-docker.git
cd burpcollaborator-docker
./collaborator up
```

On first use, the wizard asks for:

- The delegated domain, such as `collab.example.com`
- The server's public IPv4 address
- The path to your Burp Suite JAR

The command copies the JAR into the project, builds the Docker images, requests certificates for both the domain and its wildcard, and starts Collaborator. Later invocations simply start the existing installation.

### Use CLI flags

For unattended setup, provide named flags:

```bash
./collaborator up \
  --domain collab.example.com \
  --ip 1.2.3.4 \
  --jar /path/to/burpsuite.jar
```

The positional form remains available:

```bash
./collaborator up collab.example.com 1.2.3.4 /path/to/burpsuite.jar
```

### Use a config file

Copy the example and edit it:

```bash
cp collaborator.conf.example collaborator.conf
```

```ini
domain=collab.example.com
public_ip=1.2.3.4
burp_jar=/path/to/burpsuite.jar
```

Then start the deployment:

```bash
./collaborator up --config collaborator.conf
```

Relative JAR paths are resolved from the config file's directory. During first-time setup, named flags override config-file values, which makes one-off overrides possible:

```bash
./collaborator up --config collaborator.conf --ip 5.6.7.8
```

`collaborator.conf` is ignored by Git.

## Use a certificate from DigiCert or another CA

Let's Encrypt is the default, but it is not required. Supply a PEM-encoded leaf certificate, its private key, and either the CA chain or a complete full-chain file.

With CLI flags and a CA chain:

```bash
./collaborator up \
  --domain collab.example.com \
  --ip 1.2.3.4 \
  --jar /path/to/burpsuite.jar \
  --certificate-source files \
  --cert /path/to/certificate.pem \
  --key /path/to/private-key.pem \
  --chain /path/to/ca-chain.pem
```

If the CA provides a ready-made file containing the leaf certificate and intermediates, use `--fullchain` instead of `--chain`:

```bash
./collaborator up \
  --domain collab.example.com \
  --ip 1.2.3.4 \
  --jar /path/to/burpsuite.jar \
  --certificate-source files \
  --cert /path/to/certificate.pem \
  --key /path/to/private-key.pem \
  --fullchain /path/to/fullchain.pem
```

The equivalent config file entries are:

```ini
certificate_source=files
certificate_file=/path/to/certificate.pem
private_key_file=/path/to/private-key.pem
chain_file=/path/to/ca-chain.pem
# Use fullchain_file instead of chain_file when appropriate.
```

The files are copied into `burp/keys`; the container does not depend on the original paths after setup. Certificate files must be PEM encoded, the private key must match the certificate, and the certificate must cover the configured Collaborator domain and its required subdomains.

To install renewed or replacement files later, run `up` again with the file options or the same config file. If Burp is running, it is restarted with the new certificate automatically:

```bash
./collaborator up --config collaborator.conf
```

## Lifecycle commands

Start or create the deployment:

```bash
./collaborator up
```

Stop it while preserving the JAR, configuration, and certificates:

```bash
./collaborator down
```

Check its state:

```bash
./collaborator status
```

Follow the Burp container logs:

```bash
./collaborator logs
```

Check for certificate renewal:

```bash
./collaborator renew
```

Display command help:

```bash
./collaborator --help
```

## Certificate renewal

For Let's Encrypt deployments, `./collaborator renew` asks Certbot to renew certificates that are close to expiry. When renewal occurs, the new files are installed and Burp is restarted automatically. If nothing is due, Burp is left untouched.

For supplied certificates, renewal remains the responsibility of the CA or administrator. Install replacements by running `./collaborator up` with `certificate_source=files`; `./collaborator renew` will report that automatic Let's Encrypt renewal is disabled.

For unattended renewal, run the command daily from cron:

```cron
17 3 * * * cd /absolute/path/to/burpcollaborator-docker && ./collaborator renew >> certbot/logs/cron.log 2>&1
```

## Ports

The container publishes these host ports:

| Host port | Protocol | Purpose |
| --- | --- | --- |
| 53 | TCP/UDP | Authoritative DNS and interaction capture |
| 80 | TCP | HTTP interaction capture |
| 443 | TCP | HTTPS interaction capture |
| 25 | TCP | SMTP interaction capture |
| 465 | TCP | SMTPS interaction capture |
| 587 | TCP | SMTP submission interaction capture |
| 9090 | TCP | HTTP polling and metrics path |
| 9443 | TCP | HTTPS polling |

Docker-published ports can bypass ordinary UFW expectations. Review the host's Docker/UFW forwarding policy and expose only what you need. In particular, restrict polling ports to the IP addresses that should be allowed to use your private Collaborator instance.

## Configure Burp Suite

In Burp Suite, open the Collaborator server settings and use your delegated domain. This project exposes secure polling on port `9443`.

The generated server configuration is stored at `burp/conf/burp.config`. The randomly generated metrics path is printed after first-time setup.

## Update Burp Suite

Replace the stored JAR and restart the deployment:

```bash
cp /path/to/new/burpsuite.jar burp/pkg/burp.jar
./collaborator down
./collaborator up
```

## Start over completely

`./collaborator down` preserves deployment data. To repeat first-time setup, stop the containers and remove the generated state:

```bash
./collaborator down
rm -f burp/conf/burp.config burp/keys/*.pem burp/pkg/burp.jar
rm -rf certbot/letsencrypt/* certbot/logs/*
./collaborator up
```

This permanently removes the current private key, certificates, Certbot account data, logs, and copied Burp JAR. Keep backups if any of them are needed.

## Troubleshooting

### Docker is unavailable

If the command reports that it cannot access Docker, verify that the daemon is running and that the current user can run `docker info` without `sudo`.

### Port 53 is already in use

Local resolvers such as `systemd-resolved` commonly bind port 53. Identify the process before changing the host:

```bash
sudo ss -lntup '( sport = :53 )'
```

The Collaborator container cannot start until both TCP and UDP port 53 are available.

### Certificate issuance fails

Verify all of the following:

- The domain's NS record is visible from a public resolver.
- The nameserver address resolves to this server's public IP.
- Inbound TCP and UDP port 53 are permitted by the cloud firewall and host firewall.
- No other process or container is using port 53.
- The domain and public IP passed to the setup command are correct.

After correcting the problem, run `./collaborator up` again. Failed first-time setup removes its temporary container and can be retried.

## Return static web content

Burp can return custom HTML when someone visits the instance. Add a `customHttpContent` section to `burp/conf/burp.config`:

```json
{
  "customHttpContent": [
    {
      "path": "/",
      "contentType": "text/html",
      "base64Content": "<base64-encoded HTML>"
    }
  ]
}
```

Restart the deployment after editing the configuration:

```bash
./collaborator down
./collaborator up
```

## Credits

Created by [Bruno Morisson](https://twitter.com/morisson), with thanks to [Fábio Pires](https://twitter.com/fabiopirespt) and [Herman Duarte](https://twitter.com/hdontwit).
