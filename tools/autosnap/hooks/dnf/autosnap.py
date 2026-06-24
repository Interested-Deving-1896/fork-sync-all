"""
DNF plugin for autosnap.

Installed to /usr/lib/python3/dist-packages/dnf-plugins/autosnap.py
(or the distro-appropriate dnf plugin directory).

DNF calls transaction_begin before resolving/downloading and
transaction_end after the transaction commits.
"""

import dnf
import subprocess
import os


class AutoSnap(dnf.Plugin):
    name = "autosnap"

    def __init__(self, base, cli):
        super().__init__(base, cli)
        self.base = base

    def _run(self, *args):
        """Invoke autosnap, ignoring errors so dnf is never blocked."""
        try:
            subprocess.run(
                ["/usr/bin/autosnap", *args],
                check=False,
                timeout=120,
            )
        except Exception as exc:  # noqa: BLE001
            self.base.logger.warning("autosnap: %s", exc)

    def transaction(self):
        """Called after a successful transaction."""
        # Collect package names from the transaction for metadata
        pkgs = []
        for pkg in self.base.transaction.install_set:
            pkgs.append(f"+{pkg.name}-{pkg.version}")
        for pkg in self.base.transaction.remove_set:
            pkgs.append(f"-{pkg.name}-{pkg.version}")

        # Pass package list via environment variable (no stdin in post hooks)
        env = os.environ.copy()
        env["AUTOSNAP_PACKAGES"] = " ".join(pkgs)

        try:
            subprocess.run(
                ["/usr/bin/autosnap", "post", "dnf"],
                check=False,
                timeout=120,
                env=env,
            )
        except Exception as exc:  # noqa: BLE001
            self.base.logger.warning("autosnap: %s", exc)

    def pre_transaction(self):
        """Called before the transaction starts."""
        pkgs = []
        for pkg in self.base.transaction.install_set:
            pkgs.append(f"+{pkg.name}-{pkg.version}")
        for pkg in self.base.transaction.remove_set:
            pkgs.append(f"-{pkg.name}-{pkg.version}")

        env = os.environ.copy()
        env["AUTOSNAP_PACKAGES"] = " ".join(pkgs)

        try:
            subprocess.run(
                ["/usr/bin/autosnap", "pre", "dnf"],
                check=False,
                timeout=120,
                env=env,
                input="\n".join(pkgs).encode(),
            )
        except Exception as exc:  # noqa: BLE001
            self.base.logger.warning("autosnap: %s", exc)
