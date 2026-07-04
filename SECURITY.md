# Security Policy

Zova is an embedded database/runtime with native code, a C ABI, language
bindings, local file parsing, dynamic trusted extensions, and package
distribution. Please report security issues privately.

## Supported Versions

Zova is pre-1.0. Security fixes are expected to target the latest released
version and the current `main` branch.

Older pre-1.0 releases may not receive backported fixes unless the issue is
severe and the fix is low risk.

## Reporting A Vulnerability

Please do not open a public GitHub issue for vulnerabilities.

Preferred path:

1. Use GitHub private vulnerability reporting if it is enabled for this
   repository.
2. If private reporting is not available, contact the maintainer through GitHub
   and ask for a private channel for a Zova security report.

Include as much detail as you can safely share:

- affected Zova version or commit
- operating system and architecture
- affected surface: CLI, C ABI, Rust, Go, Python, `.zova` file parsing,
  extension loading, package scripts, or docs
- reproduction steps or proof of concept
- whether the issue requires opening an untrusted `.zova` file or loading an
  untrusted extension
- expected impact

## Security-Sensitive Areas

Please be especially careful around:

- `.zova` file validation and private schema checks
- backup, restore, compact, doctor, and salvage paths
- C ABI ownership, child handles, null pointers, and error mapping
- Rust/Go/Python binding memory safety and lifetime behavior
- dynamic trusted local extension loading
- extension trust-store behavior
- package and release scripts
- vendored SQLite updates

`.zova` files must never cause Zova to auto-load executable code. Dynamic
extensions are trusted native code and should only load when explicitly supplied
by the process or CLI command.

## Disclosure

After a fix is available, the maintainer may publish a security note or release
note with appropriate credit, unless you ask not to be credited.
