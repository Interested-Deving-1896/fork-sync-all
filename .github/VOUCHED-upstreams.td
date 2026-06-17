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
# Seed: generated from existing registered-imports.json source orgs.

github:Interested-Deving-1896
github:OpenOS-Project-OSP
github:OpenOS-Project-Ecosystem-OOC
github:mitchellh
github:SBOM-Community
github:CISA-SBOM-Community
github:anchore
github:aquasecurity
github:interlynk-io
github:snyk
