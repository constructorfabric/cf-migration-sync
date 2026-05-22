#!/usr/bin/env bash
# 09-create-teams.sh — create the 6 teams, populate members, assign repo access
#
# Safe to run before all members have accepted org invitations — GitHub holds
# the team memberships in a pending state until acceptance.
# Idempotent: existing teams are skipped at creation; memberships are upserted.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"
preflight

# ── Create teams ─────────────────────────────────────────────────────────────
create_team() {
  local NAME="$1" DESC="$2"
  if gh api "orgs/${TARGET_ORG}/teams" -X POST \
       -f name="$NAME" -f description="$DESC" \
       -f privacy=secret -f permission=pull \
       >/dev/null 2>&1; then
    ok "team: ${NAME}"
  else
    echo "  ~ team exists: ${NAME}"
  fi
}

log "Creating teams..."
create_team "Backend Architects"      "Cyber Fabric backend architects"
create_team "Contributors"            ""
create_team "Frontend Architects"     "Cyber Fabric frontend architects"
create_team "Governance"              "Cyber Fabric governance team"
create_team "insight-app-maintainers" "Maintainers of Insight App"
create_team "security"                "User permissions, roles, policies, rules etc."

# ── Populate teams ───────────────────────────────────────────────────────────
add_to_team() {
  local SLUG="$1"; shift
  for u in "$@"; do
    gh api "orgs/${TARGET_ORG}/teams/${SLUG}/memberships/${u}" \
      -X PUT -f role=member >/dev/null 2>&1 \
      && echo "  + ${SLUG} ← ${u}" \
      || warn "could not add ${u} to ${SLUG}"
    pause 0.3
  done
}

log "Populating Backend Architects (10)"
add_to_team backend-architects \
  binarycode ffedoroff pr0tey MikeFalcon77 nonameffh \
  Artifizer striped-zebra-dev entropyshift aviator5 capybutler

log "Populating Frontend Architects (9)"
add_to_team frontend-architects \
  getahead necobaka eddeisling m231-a Artifizer \
  GeraBart voidtopixel Last-Christmas abyssal-potato

log "Populating Governance (13)"
add_to_team governance \
  pr0tey nonameffh dobrovols frontgeeks \
  lobster40 netjerikhet Artifizer enridis \
  entropyshift lavacitalola vzhuman pm-pltfrm capybutler

log "Populating insight-app-maintainers (10)"
add_to_team insight-app-maintainers \
  mitasovr dzarlax bukem Gregory91G cyberdima \
  aleksdotbar mozhaev-dev Artifizer vzhuman cyberantonz

log "Populating security (5)"
add_to_team security \
  dobrovols netjerikhet orivaris Artifizer vzhuman

log "Populating Contributors (alexpitsikoulis excluded)"
CONTRIBUTORS=(
  i02sopop mitasovr binarycode getahead ffedoroff dzarlax pr0tey Viperwow
  dimonb MikeFalcon77 Mitriyweb nonameffh lansfy GuilleX7 necobaka dobrovols
  akshatjhalani frontgeeks Ritmix3300 bukem pavel-kalmykov maurolacy sulasen
  nanoandrew4 KvizadSaderah serg-sab denislituev hitengajjar Gregory91G Bechma
  yoskini lobster40 mattgarmon tranHieuDev23 borjafm14 albinpla cashmisa ziqwerty
  eddeisling itechmeat twh09 joseph-cx aleksdotbar lizreu
  mozhaev-dev AdrienLaaboudi fluiderson AntonBraer MightyDuckNew enjiruuuu Avi2777
  netjerikhet constructor-tech vgprod teslanika m231-a bsacrobatix orivaris
  maxcherey xiboliaren Artifizer ast2074 FinnJost claudedigon dominic1988-lgtm
  Dynaval81 7er9GX modcrafter77 tscbmstubp striped-zebra-dev enridis devjow
  entropyshift ainetx aviator5 GeraBart alizid10 hyphen-2025 voidtopixel
  bit8shift Last-Christmas Qilin101 lavacitalola vzhuman abyssal-potato pm-pltfrm
  asmith987 jalankulkija capybutler refur-nfn genericaccount-de gs-layer javiers451
  max0xf cyberantonz diffora MetricWarper il10241024
)
add_to_team contributors "${CONTRIBUTORS[@]}"

# ── Assign team → repo access ────────────────────────────────────────────────
log "Assigning insight-app-maintainers → cyber-insight & cyber-insight-front (push)"
for r in cyber-insight cyber-insight-front; do
  gh api "orgs/${TARGET_ORG}/teams/insight-app-maintainers/repos/${TARGET_ORG}/${r}" \
    -X PUT -f permission=push >/dev/null && ok "${r} (push)"
done

ok "Teams set up"
