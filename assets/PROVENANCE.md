# Kavita for TOS 7 — Binary Provenance

This package ships Kavita binaries **built from public upstream source**, not
the upstream prebuilt release artifacts, to satisfy the App Center review
requirement that everything in the deb be auditable (review finding V6).

## Audit chain (per architecture)

| Step | Evidence |
|---|---|
| 1. Upstream source | Tag `v0.9.1.4` of https://github.com/Kareadita/Kavita (public repo; commit recorded in `BUILD-INFO`) |
| 2. Public build recipe | https://github.com/Moechz/kavita/blob/main/.github/workflows/build-upstream.yml — replicates the upstream `release-workflow.yml` build steps (Node 24 `npm ci --legacy-peer-deps && npm run prod` for the WebUI, `monorepo-build.sh` for `dotnet publish -c Release --self-contained`) |
| 3. Public CI logs | GitHub Actions run (run id recorded in `BUILD-INFO`, also linked from the release) |
| 4. Hash pinning | Release `build-v0.9.1.4` carries `SHA256SUMS`; the packaging `config.env` pins the same sha256 independently (double verification) |
| 5. In-package marker | `/usr/local/kavita/bin/BUILD-INFO` (machine-readable: source tag, commit, SDK versions, run id); the packaging `verify` stage asserts `built_from=source` and the tag matches |

## Prebuilt vs from-source

Nothing in the deb comes from an unaudited prebuilt channel. The .NET runtime
files are restored by `dotnet publish` from the pinned upstream SDK/runtime
packs at build time; the WebUI is compiled from the upstream `UI/Web` Angular
sources in the same CI run. The single upstream artifact NOT rebuilt here is
the frontend `dist` — it is built from source in the same run (no dist
tarball is downloaded).

## Verification for reviewers

```sh
# On the NAS (or after unpacking the deb):
cat /usr/local/kavita/bin/BUILD-INFO
# Cross-check: tag/commit against https://github.com/Kareadita/Kavita
# Cross-check: sha256 of this deb against the release assets' SHA256SUMS
sha256sum kavita_x86_64.deb   # compare with kavita_x86_64.deb.sha256
```

Packaging (this repo): https://github.com/Moechz/kavita
Upstream project: https://github.com/Kareadita/Kavita (GPL-3.0, see
/usr/share/doc/kavita/copyright)
