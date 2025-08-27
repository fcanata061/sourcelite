#!/usr/bin/env bash
#
# sourcelite — gerenciador source-based simples
# versão: 0.5
#

set -euo pipefail

# Diretórios padrão
RECIPES_DIR="${RECIPES_DIR:-$HOME/sourcelite/recipes}"
STATE_DIR="${STATE_DIR:-$HOME/.local/share/sourcelite}"
SRC_DIR="$STATE_DIR/src"
BUILD_DIR="$STATE_DIR/build"
PKG_DIR="$STATE_DIR/pkg"
DB_DIR="$STATE_DIR/db"
LOG_DIR="$STATE_DIR/log"
HOOKS_DIR="$STATE_DIR/hooks"

PREFIX="${PREFIX:-/usr/local}"
JOBS="${JOBS:-$(nproc)}"
DESTDIR="${DESTDIR:-$PKG_DIR/stage}"

mkdir -p "$RECIPES_DIR" "$STATE_DIR" "$SRC_DIR" "$BUILD_DIR" \
         "$PKG_DIR" "$DB_DIR" "$LOG_DIR" "$HOOKS_DIR"

# Cores
RED='\033[1;31m'
GRN='\033[1;32m'
YLW='\033[1;33m'
BLU='\033[1;34m'
RST='\033[0m'

log() { echo -e "${BLU}[*]${RST} $*" >&2; }
ok()  { echo -e "${GRN}[+]${RST} $*" >&2; }
warn(){ echo -e "${YLW}[!]${RST} $*" >&2; }
err() { echo -e "${RED}[x]${RST} $*" >&2; exit 1; }

fakeroot_cmd() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        command -v fakeroot >/dev/null || err "fakeroot não encontrado"
        fakeroot "$@"
    fi
}

run_hooks() {
    local phase="$1"
    local pkg="$2"
    local dir="$HOOKS_DIR/$phase"
    if [ -d "$dir" ]; then
        for hook in "$dir"/*; do
            [ -x "$hook" ] && "$hook" "$pkg" || true
        done
    fi
}

load_recipe() {
    local pkg="$1"
    local recipe="$RECIPES_DIR/$pkg.recipe"
    [ -f "$recipe" ] || recipe="$RECIPES_DIR/$pkg.sh"
    [ -f "$recipe" ] || err "recipe não encontrada: $pkg"
    # shellcheck disable=SC1090
    source "$recipe"
}

ensure_deps() {
    local pkg="$1"
    load_recipe "$pkg"
    local dep
    for dep in "${DEPENDS[@]:-}"; do
        if [ ! -f "$DB_DIR/$dep.files" ]; then
            log "dependência faltando: $dep → instalando..."
            install_pkg "$dep"
        else
            log "dependência já instalada: $dep"
        fi
    done
}

fetch() {
    local pkg="$1"; load_recipe "$pkg"
    run_hooks pre_fetch "$pkg"
    mkdir -p "$SRC_DIR/$pkg"
    pushd "$SRC_DIR/$pkg" >/dev/null
    for url in "${SRC_URI[@]}"; do
        log "baixando $url"
        wget -c "$url"
    done
    # Checagem SHA256
    if [ -n "${SHA256[0]:-}" ]; then
        tarball="${SRC_URI[0]##*/}"
        echo "${SHA256[0]}  $tarball" | sha256sum -c - || err "checksum inválido"
    fi
    popd >/dev/null
    run_hooks post_fetch "$pkg"
}

build() {
    local pkg="$1"
    ensure_deps "$pkg"
    load_recipe "$pkg"
    run_hooks pre_build "$pkg"
    mkdir -p "$BUILD_DIR/$pkg"
    rm -rf "$BUILD_DIR/$pkg"/*

    tarball="${SRC_URI[0]##*/}"
    if [ ! -f "$SRC_DIR/$pkg/$tarball" ]; then
        err "tarball não encontrado: $tarball"
    fi

    # descobrir diretório raiz do tarball
    srcdir=$(tar -tf "$SRC_DIR/$pkg/$tarball" | head -1 | cut -d/ -f1)

    [ -d "$SRC_DIR/$pkg/$srcdir" ] || tar -xf "$SRC_DIR/$pkg/$tarball" -C "$SRC_DIR/$pkg"
    cp -a "$SRC_DIR/$pkg/$srcdir" "$BUILD_DIR/$pkg/"
    cd "$BUILD_DIR/$pkg/$srcdir"

    : "${BUILD:=true}"
    ( BUILD ) 2>&1 | tee "$LOG_DIR/$pkg.log"

    run_hooks post_build "$pkg"
}

makepkg() {
    local pkg="$1"
    ensure_deps "$pkg"
    load_recipe "$pkg"
    run_hooks pre_build "$pkg"

    rm -rf "$DESTDIR"
    mkdir -p "$DESTDIR"

    : "${INSTALL:=true}"
    ( INSTALL ) 2>&1 | tee -a "$LOG_DIR/$pkg.log"

    pkgfile="$PKG_DIR/$NAME-$VERSION.tar.zst"
    fakeroot_cmd tar -C "$DESTDIR" -I zstd -cf "$pkgfile" .
    ok "pacote criado (sem instalar): $pkgfile"
}

install_pkg() {
    local pkg="$1"
    ensure_deps "$pkg"
    load_recipe "$pkg"
    run_hooks pre_install "$pkg"

    rm -rf "$DESTDIR"
    mkdir -p "$DESTDIR"

    : "${INSTALL:=true}"
    ( INSTALL ) 2>&1 | tee -a "$LOG_DIR/$pkg.log"

    pkgfile="$PKG_DIR/$NAME-$VERSION.tar.zst"
    fakeroot_cmd tar -C "$DESTDIR" -I zstd -cf "$pkgfile" .
    ok "pacote criado: $pkgfile"

    fakeroot_cmd rsync -a "$DESTDIR"/ /

    find "$DESTDIR" -type f | sed "s#^$DESTDIR##" > "$DB_DIR/$pkg.files"

    run_hooks post_install "$pkg"
    ok "instalado: $pkg"
}

installpkg() {
    local file="$1"
    [ -f "$file" ] || err "arquivo não encontrado: $file"

    rm -rf "$DESTDIR"
    mkdir -p "$DESTDIR"

    log "extraindo pacote: $file"
    case "$file" in
        *.tar.zst) tar -C "$DESTDIR" -I zstd -xf "$file" ;;
        *.tar.gz)  tar -C "$DESTDIR" -zxf "$file" ;;
        *.tar.xz)  tar -C "$DESTDIR" -Jxf "$file" ;;
        *) err "formato desconhecido: $file" ;;
    esac

    fakeroot_cmd rsync -a "$DESTDIR"/ /

    pkg=$(basename "$file" | sed 's/\.\(tar\.zst\|tar\.gz\|tar\.xz\)$//')

    find "$DESTDIR" -type f | sed "s#^$DESTDIR##" > "$DB_DIR/$pkg.files"

    ok "pacote instalado: $pkg"
}

remove_pkg() {
    local pkg="$1"
    run_hooks pre_remove "$pkg"
    [ -f "$DB_DIR/$pkg.files" ] || err "não registrado: $pkg"
    while read -r f; do
        [ -n "$f" ] || continue
        case "$f" in
            "$PREFIX"/*) fakeroot_cmd rm -vf "/$f" ;;
            *) warn "ignorado fora do PREFIX: $f" ;;
        esac
    done < "$DB_DIR/$pkg.files"
    rm -f "$DB_DIR/$pkg.files"
    run_hooks post_remove "$pkg"
    ok "removido: $pkg"
}

list_recipes() { ls "$RECIPES_DIR" | sed 's/\.\(recipe\|sh\)$//' | sort; }
list_installed() { ls "$DB_DIR"/*.files 2>/dev/null | xargs -n1 basename | sed 's/.files//' || true; }

info_pkg() {
    local pkg="$1"; load_recipe "$pkg"
    echo -e "${BLU}== $NAME $VERSION ==${RST}"
    echo "SRC: ${SRC_URI[*]}"
    echo "DEPENDS: ${DEPENDS[*]:-nenhum}"
}

sync_repo() {
    if [ -d "$RECIPES_DIR/.git" ]; then
        (cd "$RECIPES_DIR" && git pull && git add . && git commit -am "sync" && git push) || true
    fi
}

doctor() {
    for tool in wget rsync git make fakeroot sha256sum; do
        command -v "$tool" >/dev/null || warn "falta: $tool"
    done
}

usage() {
cat <<EOF
sourcelite — gerenciador source-based simples
uso: sourcelite <comando> [pacote]

comandos:
  new <nome>       cria recipe básica
  fetch <pkg>      baixa source
  build <pkg>      compila (com deps)
  makepkg <pkg>    compila e gera pacote (sem instalar)
  install <pkg>    instala e empacota (com deps)
  installpkg <arq> instala direto de pacote .tar.zst/.tar.gz
  remove <pkg>     remove
  list             lista recipes
  installed        lista instalados
  info <pkg>       mostra info
  sync             sincroniza git recipes
  doctor           checa deps
EOF
}

new_recipe() {
    local pkg="$1"
    cat > "$RECIPES_DIR/$pkg.recipe" <<EOR
NAME="$pkg"
VERSION="1.0"
SRC_URI=("http://exemplo.com/$pkg-\$VERSION.tar.gz")
SHA256=()
PATCHES=()
DEPENDS=()  # ex: ("zlib" "openssl")

BUILD() {
  ./configure --prefix=\$PREFIX
  make -j\$JOBS
}

INSTALL() {
  make DESTDIR=\$DESTDIR install
}
EOR
    ok "recipe criada: $RECIPES_DIR/$pkg.recipe"
}

cmd="${1:-help}"
case "$cmd" in
    new) shift; new_recipe "$@";;
    fetch) shift; fetch "$@";;
    build) shift; build "$@";;
    makepkg) shift; makepkg "$@";;
    install) shift; install_pkg "$@";;
    installpkg) shift; installpkg "$@";;
    remove) shift; remove_pkg "$@";;
    list) list_recipes;;
    installed) list_installed;;
    info) shift; info_pkg "$@";;
    sync) sync_repo;;
    doctor) doctor;;
    help|--help|-h|"") usage;;
    *) err "comando desconhecido: $cmd";;
esac
