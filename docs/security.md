# Security

## API authentication

- If `API_TOKEN` is set, admin routes require `Authorization: Bearer <token>`.

## Supply chain

- Prefer `oci` artifacts with signed images and digests.
- Prefer pinned Python versions (e.g., `==1.4.2`) or upper bounds.

## Policies (extensible)

- License allow/deny lists at ingest and install time.
- Optional signature and SBOM validation hooks (stubs in current release).

## Network egress

- Installer performs `pip`, `docker`, and `git` operations.
- Use allowlists/proxies as required by your environment.

## Secrets

- Do not commit `.env`. Provide tokens via Secret managers where possible.
