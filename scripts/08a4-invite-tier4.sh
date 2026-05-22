#!/usr/bin/env bash
# 08a4-invite-tier4.sh — Tier 4: remaining contributors (full batch)

set -euo pipefail

USERS=(
  7er9GX
  AdrienLaaboudi
  albinpla
  AntonBraer
  asmith987
  ast2074
  Avi2777
  bit8shift
  borjafm14
  bsacrobatix
  cashmisa
  claudedigon
  constructor-tech
  denislituev
  devjow
  diffora
  dimonb
  Dynaval81
  enjiruuuu
  FinnJost
  fluiderson
  genericaccount-de
  GuilleX7
  hitengajjar
  i02sopop
  il10241024
  itechmeat
  javiers451
  joseph-cx
  KvizadSaderah
  lansfy
  lizreu
  maurolacy
  max0xf
  maxcherey
  MetricWarper
  MightyDuckNew
  Mitriyweb
  nanoandrew4
  pavel-kalmykov
  Qilin101
  refur-nfn
  Ritmix3300
  serg-sab
  sulasen
  teslanika
  tranHieuDev23
  twh09
  vgprod
  Viperwow
  xiboliaren
  ziqwerty
)

for USER in "${USERS[@]}"; do
  echo "Inviting ${USER}..."
  USER_ID=$(gh api "users/${USER}" --jq '.id')
  gh api "orgs/constructorfabric/invitations" \
    -X POST \
    -F invitee_id="$USER_ID" \
    -f role="direct_member" || true
done
