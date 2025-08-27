#!/usr/bin/env bash
#
# sourcelite — gerenciador source-based simples
# autor: você :)
# versão: 0.1
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

log() { echo "[*] $*" >&2; }
err() { echo "[!] $*" >&2; exit 1; }

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

fetch() {
    local pkg="$1"; load_recipe "$pkg"
    run_hooks pre_fetch "$pkg"
    mkdir -p "$SRC_DIR/$pkg"
    pushd "$SRC_DIR/$pkg" >/dev/null
    for url in "${SRC_URI[@]}"; do
        log "baixando $url"
        wget -c "$url"
    done
    popd >/dev/null
    run_hooks post_fetch "$pkg"
}

build() {
    local pkg="$1"; load_recipe "$pkg"
    run_hooks pre_build "$pkg"
    mkdir -p "$BUILD_DIR/$pkg"
    rm -rf "$BUILD_DIR/$pkg"/*
    tarball="${SRC_URI[0]##*/}"
    srcdir="${tarball%.tar.*}"
    [ -d "$SRC_DIR/$pkg/$srcdir" ] || tar -xf "$SRC_DIR/$pkg/$tarball" -C "$SRC_DIR/$pkg"
    cp -a "$SRC_DIR/$pkg/$srcdir" "$BUILD_DIR/$pkg/"
    cd "$BUILD_DIR/$pkg/$srcdir"
    : "${BUILD:=true}"
    BUILD |& tee "$LOG_DIR/$pkg.log"
    run_hooks post_build "$pkg"
}

install_pkg() {
    local pkg="$1"; load_recipe "$pkg"
    run_hooks pre_install "$pkg"
    rm -rf "$DESTDIR"
    mkdir -p "$DESTDIR"
    : "${INSTALL:=true}"
    INSTALL |& tee -a "$LOG_DIR/$pkg.log"
    rsync -a "$DESTDIR"/ / || true
    # registrar
    find "$DESTDIR" -type f | sed "s#^$DESTDIR##" > "$DB_DIR/$pkg.files"
    run_hooks post_install "$pkg"
    log "instalado: $pkg"
}

remove_pkg() {
    local pkg="$1"
    run_hooks pre_remove "$pkg"
    [ -f "$DB_DIR/$pkg.files" ] || err "não registrado: $pkg"
    while read -r f; do
        rm -vf "/$f" || true
    done < "$DB_DIR/$pkg.files"
    rm -f "$DB_DIR/$pkg.files"
    run_hooks post_remove "$pkg"
    log "removido: $pkg"
}

list_recipes() { ls "$RECIPES_DIR" | sed 's/\.\(recipe\|sh\)$//' | sort; }
list_installed() { ls "$DB_DIR"/*.files 2>/dev/null | xargs -n1 basename | sed 's/.files//' || true; }

info_pkg() {
    local pkg="$1"; load_recipe "$pkg"
    echo "== $NAME $VERSION =="
    echo "SRC: ${SRC_URI[*]}"
    echo "DEPENDS: ${DEPENDS[*]:-nenhum}"
}

sync_repo() {
    if [ -d "$RECIPES_DIR/.git" ]; then
        (cd "$RECIPES_DIR" && git pull && git add . && git commit -am "sync" && git push) || true
    fi
}

doctor() {
    for tool in wget rsync git make; do
        command -v "$tool" >/dev/null || echo "falta: $tool"
    done
}

usage() {
cat <<EOF
sourcelite — gerenciador source-based simples
uso: sourcelite <comando> [pacote]

comandos:
  new <nome>       cria recipe básica
  fetch <pkg>      baixa source
  build <pkg>      compila
  install <pkg>    instala
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
DEPENDS=()

BUILD() {
  ./configure --prefix=\$PREFIX
  make -j\$JOBS
}

INSTALL() {
  make DESTDIR=\$DESTDIR install
}
EOR
    log "recipe criada: $RECIPES_DIR/$pkg.recipe"
}

cmd="${1:-help}"
case "$cmd" in
    new) shift; new_recipe "$@";;
    fetch) shift; fetch "$@";;
    build) shift; build "$@";;
    install) shift; install_pkg "$@";;
    remove) shift; remove_pkg "$@";;
    list) list_recipes;;
    installed) list_installed;;
    info) shift; info_pkg "$@";;
    sync) sync_repo;;
    doctor) doctor;;
    help|--help|-h|"") usage;;
    *) err "comando desconhecido: $cmd";;
esac
