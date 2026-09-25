# Repository guidance

## Project and constraints

AcreetionOS Horizon Community Edition is an x86_64 Arch Linux ISO with a
pinned GNOME 48 desktop on XLibre/X11. Read README.md for product intent and
inspect the relevant implementation before changing behavior.

- Preserve the native X11 desktop; Wayland is not the Horizon target.
- Installed-host updates use Freeman and verified system images. Do not
  introduce rolling host upgrades that replace the pinned desktop stack.
- Pacman remains part of ISO construction, online installer operations, and
  application containers; distinguish these from installed-host updates.
- Preserve offline installer support, explicit online choices, and user-data
  protection when changing installation or recovery behavior.

## Repository map

- `airootfs/`: filesystem overlay shipped in the image. Paths here describe
  the target OS, not the development host.
- `airootfs/etc/calamares/`: installer settings, modules, and package groups.
- `airootfs/usr/local/lib/horizon-installer/`: first-party Python installer,
  hardware detection, and data migration helpers.
- `airootfs/usr/local/bin/`: first-party runtime tools, onboarding, diagnostics,
  and image update entry points.
- `profiledef.sh`: archiso metadata, boot modes, and target file permissions.
- `packages.x86_64`, `bootstrap_packages.x86_64`, `pacman.conf`: package inputs
  and build repository configuration.
- `xlibre-patches/`: pinned desktop sources, patches, and package builder.
- `tools/freeman/`: Rust workspace. Its CLI binary is named `pamac` during
  compilation and is copied as `freeman` by the build scripts.
- `grub/`, `syslinux/`, `efiboot/`: bootloader configuration.
- `tests/`: Python unittest coverage for installer features and profiles.
- `chatbot-ui/`, `installer/chatbot/`: separate React/webpack packages.
- `.github/workflows/build-iso.yml`, `.gitlab-ci.yml`: ISO build pipelines;
  their build steps differ, so inspect the pipeline relevant to a change.

## Development and validation

Run commands from the repository root unless stated otherwise. Choose checks
for the component changed; a full ISO build is not a routine unit test.

- Installer tests (Python 3 and PyYAML required):
  `python3 -m unittest discover -s tests -p 'test_*.py'`
- Shell edits: run `bash -n` on each changed Bash script. Use ShellCheck when
  available, accounting for archiso profile variables consumed externally.
- Freeman tests:
  `cargo test --workspace --manifest-path tools/freeman/Cargo.toml`
  Some CLI integration tests exercise external package/AUR behavior; report
  environment or network limitations separately from code failures.
- Freeman release build: `./build-freeman.sh`. It places the renamed binary
  in `.horizon-build/` by default.
- C wrapper: `make` builds `mkarchiso_wrapper` from `mkarchiso.c`; it does not
  build the ISO. Avoid `make install` for routine validation.
- For either chatbot package, run `npm run build` inside that package after
  installing its dependencies. Neither package declares a test script.
- Run `git diff --check` before finishing. Report checks actually performed
  and any checks that could not run.

For behavior changes, extend relevant first-party tests where useful. Avoid
executing installer jobs, recovery operations, or image writes on the host as
substitutes for tests; use a disposable VM for end-to-end OS validation.

## ISO builds

`./build.sh` builds patched desktop packages, builds and stages Freeman into
the overlay, cleans prior ISO work, and invokes mkarchiso. It requires an Arch
build environment with the required tools, network access, and privileges for
image construction. See the CI definitions for dependency setup.

Defaults include `.horizon-build/` for intermediate packages, `work/` for ISO
work, and `../ISO` for output. Inspect `HORIZON_BUILD_DIR`, `WORK_DIR`,
`ISO_OUT_DIR`, and `PACMAN_CONF` overrides before running. The full build
changes overlay executable bits and removes previous work/output through
`refresh.sh` or its cleanup fallback. Read cleanup scripts before using them.

For desktop-only work, inspect `./build-horizon-xlibre.sh` and
`xlibre-patches/README.md` for the patched-package workflow.

## Editing conventions

- Match surrounding shell, Python, Rust, and configuration style; keep changes
  focused and preserve unrelated local work.
- When adding runtime executables, check executable modes and the
  `file_permissions` mapping in `profiledef.sh`.
- Keep Calamares module IDs, sequence ordering, referenced scripts, and online
  versus offline profile generation consistent.
- Narrow searches to first-party directories. The overlay contains vendored
  system libraries and binaries; avoid broad formatting or replacement across
  `airootfs/usr/lib/` and installed `node_modules/` trees.
- Do not add build outputs, dependency trees, package caches, ISO images, or
  runtime database contents to a change. Not all generated paths are ignored.
- Recent commits use descriptive subjects such as `fix(build): ...` and
  `feat(horizon): ...`; follow that style when a commit is requested.
