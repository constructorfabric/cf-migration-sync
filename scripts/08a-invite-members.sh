#!/usr/bin/env bash
# 08a-invite-members.sh — invite all cyberfabric members to constructorfabric
#
# Excluded intentionally: alexpitsikoulis, dfc-Acronis, gaidar

set -euo pipefail

USERS=(
  Artifizer
  vzhuman
  7er9GX
  abyssal-potato
  AdrienLaaboudi
  ainetx
  akshatjhalani
  albinpla
  aleksdotbar
  alizid10
  AntonBraer
  asmith987
  ast2074
  Avi2777
  aviator5
  Bechma
  binarycode
  bit8shift
  borjafm14
  bsacrobatix
  bukem
  capybutler
  cashmisa
  claudedigon
  constructor-tech
  cyberantonz
  cyberdima
  denislituev
  devjow
  diffora
  dimonb
  dobrovols
  dominic1988-lgtm
  Dynaval81
  dzarlax
  eddeisling
  enjiruuuu
  enridis
  entropyshift
  ffedoroff
  FinnJost
  fluiderson
  frontgeeks
  genericaccount-de
  GeraBart
  getahead
  Gregory91G
  gs-layer
  GuilleX7
  hitengajjar
  hyphen-2025
  i02sopop
  il10241024
  itechmeat
  jalankulkija
  javiers451
  joseph-cx
  KvizadSaderah
  lansfy
  Last-Christmas
  lavacitalola
  lizreu
  lobster40
  m231-a
  mattgarmon
  maurolacy
  max0xf
  maxcherey
  MetricWarper
  MightyDuckNew
  MikeFalcon77
  mitasovr
  Mitriyweb
  modcrafter77
  mozhaev-dev
  nanoandrew4
  necobaka
  netjerikhet
  nonameffh
  orivaris
  pavel-kalmykov
  pm-pltfrm
  pr0tey
  Qilin101
  refur-nfn
  Ritmix3300
  serg-sab
  striped-zebra-dev
  sulasen
  teslanika
  tranHieuDev23
  tscbmstubp
  twh09
  vgprod
  Viperwow
  voidtopixel
  xiboliaren
  yoskini
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
