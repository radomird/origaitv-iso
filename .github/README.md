<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="../branding/logo.svg">
    <img alt="OrigaiTV" src="../branding/logo-light.svg" width="520">
  </picture>
</p>

<p align="center">
  <b>The USB installer for OrigaiTV, the world's first open-source agentic TV OS.</b><br>
  Powered by <a href="https://omarchy.org">Omarchy</a>.
</p>

---

This is where the OrigaiTV USB stick comes from.

Put the ISO on a stick and start your box from it. The TV shows a code. Scan it with your phone, pick the disk and tap "Erase and install". That's the only question. The box installs OrigaiTV, restarts by itself, and your phone carries on with setup.

No phone to hand? Pick the disk with the keyboard and press Enter. Want every question Omarchy's own installer asks? Press Ctrl+C on the first screen.

It's for x86_64 PCs, and installing erases the disk you pick. [origaitv-os's README](https://github.com/radomird/origaitv-os#install-it) walks you through all of it, from the download to home.

## Getting the ISO

The ISO is on [the releases page](https://github.com/radomird/origaitv-iso/releases), in the newest release. Until 1.0 is out, that's a release candidate. Its notes have the download link and the ISO's checksum. The file is named after its version, like `origaitv-1.0.0-rc2-x86_64.iso`, and it's about 6.7 GB.

To check your download, grab its checksum and the checksum's signature too. They're at the ISO's address with `.sha256` and `.sha256.sig` on the end. Put them in the folder with the ISO and run this, with your ISO's version in place of `1.0.0-rc2`:

```
curl -LO https://raw.githubusercontent.com/radomird/origaitv-pkgs/main/origaitv-keyring/origaitv.gpg
gpg --import origaitv.gpg
gpg --verify origaitv-1.0.0-rc2-x86_64.iso.sha256.sig origaitv-1.0.0-rc2-x86_64.iso.sha256
sha256sum -c origaitv-1.0.0-rc2-x86_64.iso.sha256
```

The first two lines fetch OrigaiTV's public key. You only need them once. `gpg --verify` should say "Good signature", from the key `B4D4 7D67 1A03 84BF 7516 4CF1 AD68 7DD5 C049 475F`. That tells you the checksum is mine. gpg also warns that you haven't told it to trust the key, and that's fine. `sha256sum -c` then tells you the ISO matches the checksum, and prints the ISO's name with `OK`. On a Mac it's `shasum -a 256 -c`.

There's one more ISO, for trying what's next: last night's edge build, like `origaitv-0.2.0.r831.g59f9f8164-x86_64.iso`. Edge's version is the one `origaitv version` prints on a box you install from it.

A box installed from a release candidate or from edge gets every new build as it's made, not only the releases. To move it to the releases, run `origaitv channel stable` on it, and then `origaitv update`. The stable ISO, like `origaitv-1.0.0-x86_64.iso`, is coming soon, with 1.0.

The ISO is too big for GitHub's release files, so it lives on Cloudflare R2, at iso.origai.tv. Since the file's name changes with every version, a small file for each kind says which ISO is the newest: [rc.json](https://iso.origai.tv/iso/rc.json) and [edge.json](https://iso.origai.tv/iso/edge.json), and `stable.json` once 1.0 is out. Those links don't change. Each has the ISO's file name, version, size in bytes, sha256 and address, and the addresses of its checksum and the checksum's signature (`sha256Url` and `sigUrl`). Older ISOs aren't kept.

## How an ISO gets made

Every release tag builds the ISO here, a release candidate's too. Before you see it, it has to pass a test run in GitHub Actions: a VM installs it by itself, then boots what it installed into OrigaiTV's TV session. Then its checksum gets signed and the ISO goes to R2 (`bin/origaitv-iso-publish`). Edge's ISO is made by origaitv-os's nightly run, and it's only kept when every check there passes.

## Something went wrong?

[Tell me what happened](https://github.com/radomird/origaitv-iso/issues/new/choose): how far it got, and what the TV showed when it stopped. For a security problem, please [tell me privately](https://github.com/radomird/origaitv-iso/security/advisories/new) first.

## Support OrigaiTV

OrigaiTV is free and open source. If you'd like to help, you can [chip in through Stripe](https://buy.stripe.com/7sY4gzeMjdZs1oo7Wbgfu00) and pick the amount yourself. Thank you!

## Powered by Omarchy

This repo is a fork of [omacom/omarchy-iso](https://github.com/omacom/omarchy-iso), pinned to an upstream commit. I never edit Omarchy's files here. OrigaiTV only adds its own: the first screen, the build workflow, the settings that point the build at [`origaitv-os`](https://github.com/radomird/origaitv-os), and the installer logo. Omarchy's own README, with how to build and test an ISO yourself, is at [`../README.md`](../README.md).

Omarchy and its installer are MIT-licensed, and the [licence](../LICENSE) stays as it is. OrigaiTV's additions are copyright Radomir Drndarski and use the same licence. OrigaiTV isn't made or endorsed by the Omarchy project.

Some files here are about other machines Omarchy supports, such as an ARM laptop. They're Omarchy's. OrigaiTV is x86_64 only.
