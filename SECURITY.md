# Security policy

## Scope

Moriarty modifies kernel parameters, module policy, NetworkManager identity
defaults, profile DNS, and resolver routing. It stores backups and reports under
`/root` with restrictive permissions.

## Threat model

- Protects local host information and DNS metadata from ordinary network
  observers.
- Does not provide anonymity: destinations, SNI, cookies, accounts, and
  connection metadata may still identify a user.
- Does not install or configure a firewall despite aligning UFW's sysctl file.
- Does not cover already loaded kernel modules, built-in modules, or privileged
  `insmod`.

The full component-by-component matrix, including what each feature does not
protect against and the conditions it depends on, is in
[docs/THREAT-MODEL.md](docs/THREAT-MODEL.md). Integration coverage and its
current gaps are documented in [docs/TESTING.md](docs/TESTING.md).

## Reporting vulnerabilities

Do not place exploit details in public issues. Use GitHub private vulnerability
reporting or contact the maintainer through the repository page.

Include the output of:

```bash
./moriarty.sh --check
cat /tmp/moriarty-check-report.txt
```

and sanitize hostname, addresses, and paths before sharing.
