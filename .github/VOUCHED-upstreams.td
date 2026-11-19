# VOUCHED-upstreams.td — trusted upstream orgs/users for registered-imports.json
#
# Format: same as VOUCHED.td but entries represent GitHub orgs or users
# whose repos are trusted for import via registered-imports.json.
#
# validate-registered-imports.py --vouch-check reads this file and warns
# when an import's source org/user is not listed here.
#
# This is advisory only — imports are not blocked, only flagged.
# Add an org/user here after reviewing their repos for supply-chain risk.
#
# Seeded from all source orgs present in registered-imports.json (2026-06-17).
# Review periodically — remove entries for orgs no longer in the imports file.

# ── Mirror chain (always trusted) ─────────────────────────────────────────────
github:Interested-Deving-1896
github:OpenOS-Project-OSP
github:OpenOS-Project-Ecosystem-OOC

# ── SBOM / supply-chain tooling ───────────────────────────────────────────────
github:mitchellh
github:SBOM-Community
github:CISA-SBOM-Community
github:anchore
github:aquasecurity
github:interlynk-io
github:snyk

# ── All orgs present in registered-imports.json ───────────────────────────────
github:89luca89
github:accessibility-tools
github:ActivitySmithHQ
github:adnanh
github:affaan-m
github:Alex313031
github:alexkli
github:Amalzalu
github:andrachiritoiu
github:andrewthetechie
github:aplund
github:apvarun
github:ashos
github:automateyournetwork
github:Bash-it
github:bashly-framework
github:beamitpal
github:CachyOS
github:CadmusCJung
github:canalplus
github:chevdor
github:chopratejas
github:CodesOfRishi
github:Community-Access
github:DamageLabs
github:deadc0de6
github:dequelabs
github:devcontainers
github:digitaltvguy
github:dontlaugh
github:doriaviram
github:dparoli
github:dyne
github:emmanuelnk
github:espeak-ng
github:firecracker-microvm
github:fjaeckel
github:Flux159
github:fmartini23
github:github
github:githubexporter
github:GoogleChromeLabs
github:hakoerber
github:harnexa
github:homoluctus
github:ioncakephper
github:jakwuh
github:jcsteh
github:joaoGabriel55
github:jogor9
github:josecelano
github:jsbmg
github:KDE
github:Keylan
github:kivo360
github:kohofinancial
github:konzy
github:leifdenby
github:liblouis
github:Lifailon
github:lifo-sh
github:locus313
github:loft-sh
github:lowlighter
github:lxc
github:msoap
github:nanopack
github:Narven
github:nathanielop
github:nautilus-cyberneering
github:niabhail
github:niklasberglund
github:nikotsy
github:nmicovic
github:notgiven688
github:nvaccess
github:omyldrm
github:pa11y
github:PavaraM
github:pinkorca
github:progrium
github:quitecode9-lab
github:rajshah9305
github:rakles
github:rmatsuoka
github:rugix
github:rust-lang
github:scottvr
github:sevenreasons
github:siderolabs
github:SupraSummus
github:Sync-in
github:tchartron
github:tislib
github:topboyasante
github:Trusera
github:tsirysndr
github:turahe
github:tushkum34-cloud
github:ublue-os
github:UltiRequiem
github:uutils
github:vadmium
github:Vaelatern
github:VictoriaMetrics
github:vivekchand
github:windsorcli
github:yennanliu
github:zce
github:zdk
github:zen-fs

# ── Non-GitHub platforms ───────────────────────────────────────────────────────
# KDE self-hosted GitLab (invent.kde.org)
kde:websites
