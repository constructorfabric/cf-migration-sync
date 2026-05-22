#!/usr/bin/env bash
# 08a-invite-members.sh — send org invitations to all source-org members
#
# Each member must accept the email/notification before they appear in the
# target org. Owners get 'admin' role; everyone else gets 'direct_member'.
# Idempotent: existing members and pending invites are skipped.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"
preflight

OWNERS=(Artifizer vzhuman)

# NOTE: alexpitsikoulis, dfc-Acronis, gaidar are intentionally excluded.
MEMBERS=(
  7er9GX abyssal-potato AdrienLaaboudi ainetx akshatjhalani
  albinpla aleksdotbar alizid10 AntonBraer
  asmith987 ast2074 Avi2777 aviator5 Bechma
  binarycode bit8shift borjafm14 bsacrobatix bukem
  capybutler cashmisa claudedigon constructor-tech cyberantonz
  cyberdima denislituev devjow diffora
  dimonb dobrovols dominic1988-lgtm Dynaval81 dzarlax
  eddeisling enjiruuuu enridis entropyshift ffedoroff
  FinnJost fluiderson frontgeeks genericaccount-de
  GeraBart getahead Gregory91G gs-layer GuilleX7
  hitengajjar hyphen-2025 i02sopop il10241024 itechmeat
  jalankulkija javiers451 joseph-cx KvizadSaderah lansfy
  Last-Christmas lavacitalola lizreu lobster40 m231-a
  mattgarmon maurolacy max0xf maxcherey MetricWarper
  MightyDuckNew MikeFalcon77 mitasovr Mitriyweb modcrafter77
  mozhaev-dev nanoandrew4 necobaka netjerikhet nonameffh
  orivaris pavel-kalmykov pm-pltfrm pr0tey Qilin101
  refur-nfn Ritmix3300 serg-sab striped-zebra-dev sulasen
  teslanika tranHieuDev23 tscbmstubp twh09 vgprod
  Viperwow voidtopixel xiboliaren yoskini ziqwerty
)

invite() {
  local LOGIN="$1" ROLE="$2"
  USER_ID=$(gh api "users/${LOGIN}" --jq '.id' 2>/dev/null || echo "")
  if [ -z "$USER_ID" ]; then
    warn "user not found: ${LOGIN}"
    return
  fi
  if gh api "orgs/${TARGET_ORG}/invitations" \
       -X POST -f invitee_id="${USER_ID}" -f role="${ROLE}" \
       >/dev/null 2>&1; then
    ok "invited ${LOGIN} (${ROLE})"
  else
    # 422 = already member or pending — treat as success silently
    echo "  ~ ${LOGIN}: already member or pending"
  fi
  pause 0.5
}

log "Inviting owners (${#OWNERS[@]})"
for u in "${OWNERS[@]}"; do invite "$u" admin; done

log "Inviting members (${#MEMBERS[@]})"
for u in "${MEMBERS[@]}"; do invite "$u" direct_member; done

log "Done. Pending invitations:"
gh api "orgs/${TARGET_ORG}/invitations" --paginate --jq '.[].login' | wc -l
