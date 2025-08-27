#!/usr/bin/env bash
#
# sourcelite — gerenciador source-based simples
# versão: 0.6
#

set -euo pipefail

# =========================
# Diretórios e variáveis
# =========================
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

# =========================
# Cores
# =========================
RED='\033[1;31m'
GRN='\033[1;32m'
YLW='\033[1;33m'
BLU='\033[1;34m'
RST='\033[0m'

log()  { echo -e "${BLU}[*]${RST} $*" >&2; }
ok()   { echo -e "${GRN}[+]${RST} $*" >&2; }
warn() { echo -e "${YLW}[!]${RST} $*" >&2; }
err()  { echo -e "${RED}[x]${RST} $*" >&2; exit 1; }

# =========================
# Helpers
# =========================
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
    local pkg="${2:-}"
    local dir="$HOOKS_DIR/$phase"
    if [ -d "$dir" ]; then
        for hook in "$dir"/*; do
            [ -x "$hook" ] && "$hook" "$pkg" || true
        done
    fi
}

load_recipe() {
    local pkg="$1"
    NAME=""; VERSION=""; SRC_URI=(); SHA256=(); PATCHES=(); DEPENDS=()
    local recipe="$RECIPES_DIR/$pkg.recipe"
    [ -f "$recipe" ] || recipe="$RECIPES_DIR/$pkg.sh"
    [ -f "$recipe" ] || err "recipe não encontrada: $pkg"
    # shellcheck disable=SC1090
    source "$recipe"
    [ -n "${NAME:-}" ] || NAME="$pkg"
    [ -n "${VERSION:-}" ] || VERSION="1.0"
}

# Patches opcionais definidos na receita (PATCHES=("file.patch" ...))
apply_patches_if_any() {
    local where="$1"  # diretório do código-fonte
    [ "${#PATCHES[@]:-0}" -gt 0 ] || return 0
    pushd "$where" >/dev/null
    for p in "${PATCHES[@]}"; do
        if [ -f "$p" ]; then
            log "aplicando patch: $p"
            patch -p1 < "$p"
        elif [ -f "$RECIPES_DIR/$p" ]; then
            log "aplicando patch: $RECIPES_DIR/$p"
            patch -p1 < "$RECIPES_DIR/$p"
        else
            warn "patch não encontrado: $p (ignorado)"
        fi
    done
    popd >/dev/null
}

# Rastreio de dependências já processadas (evita loops)
declare -A __VISITED_DEPS=()

ensure_deps() {
    local pkg="$1"
    if [[ -n "${__VISITED_DEPS[$pkg]:-}" ]]; then return 0; fi
    __VISITED_DEPS[$pkg]=1

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

# Descobre diretório raiz após extrair um tar.* (ou usa o próprio se não houver diretório topo)
discover_srcdir() {
    local tarball="$1" base
    base=$(tar -tf "$tarball" | head -1 | cut -d/ -f1)
    if [ -z "$base" ]; then
        echo "."
    else
        echo "$base"
    fi
}

# Verifica se uma dependência é usada por algum outro pacote
dep_in_use_elsewhere() {
    local dep="$1" exclude_pkg="$2"
    local f
    shopt -s nullglob
    for f in "$DB_DIR"/*.deps; do
        [ "$(basename "$f")" = "$exclude_pkg.deps" ] && continue
        if grep -qx "$dep" "$f"; then
            shopt -u nullglob
            return 0
        fi
    done
    shopt -u nullglob
    return 1
}

# =========================
# Ações principais
# =========================
fetch() {
    local pkg="$1"
    load_recipe "$pkg"
    run_hooks pre_fetch "$pkg"

    mkdir -p "$SRC_DIR/$pkg"
    pushd "$SRC_DIR/$pkg" >/dev/null
    for url in "${SRC_URI[@]}"; do
        log "baixando $url"
        wget -c "$url"
    done

    # Checagem SHA256 (apenas do primeiro tarball, se definido)
    if [ -n "${SHA256[0]:-}" ]; then
        local tarball="${SRC_URI[0]##*/}"
        echo "${SHA256[0]}  $tarball" | sha256sum -c - || err "checksum inválido: $tarball"
        ok "checksum ok: $tarball"
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

    local tarball="$SRC_DIR/$pkg/${SRC_URI[0]##*/}"
    [ -f "$tarball" ] || err "tarball não encontrado: ${SRC_URI[0]##*/} (rode: sourcelite fetch $pkg)"

    local srcroot
    srcroot=$(discover_srcdir "$tarball")
    [ -d "$SRC_DIR/$pkg/$srcroot" ] || tar -xf "$tarball" -C "$SRC_DIR/$pkg"

    # Copiar fonte para área de build
    cp -a "$SRC_DIR/$pkg/$srcroot" "$BUILD_DIR/$pkg/src"
    cd "$BUILD_DIR/$pkg/src"

    apply_patches_if_any "$PWD"

    : "${BUILD:=true}"
    ( BUILD ) 2>&1 | tee "$LOG_DIR/$pkg.log"

    run_hooks post_build "$pkg"
    ok "build concluído: $pkg"
}

makepkg() {
    local pkg="$1"
    ensure_deps "$pkg"
    load_recipe "$pkg"
    run_hooks pre_build "$pkg"

    # garantir que o build foi feito (se receita usa artefatos do build dir)
    if [ ! -d "$BUILD_DIR/$pkg/src" ]; then
        build "$pkg"
    fi

    rm -rf "$DESTDIR"
    mkdir -p "$DESTDIR"
    pushd "$BUILD_DIR/$pkg/src" >/dev/null

    : "${INSTALL:=true}"
    ( INSTALL ) 2>&1 | tee -a "$LOG_DIR/$pkg.log"

    popd >/dev/null

    local pkgfile="$PKG_DIR/$NAME-$VERSION.tar.zst"
    fakeroot_cmd tar -C "$DESTDIR" -I zstd -cf "$pkgfile" .
    ok "pacote criado (sem instalar): $pkgfile"
}

install_pkg() {
    local pkg="$1"
    ensure_deps "$pkg"
    load_recipe "$pkg"
    run_hooks pre_install "$pkg"

    # construir se necessário
    if [ ! -d "$BUILD_DIR/$pkg/src" ]; then
        build "$pkg"
    fi

    rm -rf "$DESTDIR"
    mkdir -p "$DESTDIR"
    pushd "$BUILD_DIR/$pkg/src" >/dev/null

    : "${INSTALL:=true}"
    ( INSTALL ) 2>&1 | tee -a "$LOG_DIR/$pkg.log"

    popd >/dev/null

    # Empacotar
    local pkgfile="$PKG_DIR/$NAME-$VERSION.tar.zst"
    fakeroot_cmd tar -C "$DESTDIR" -I zstd -cf "$pkgfile" .
    ok "pacote criado: $pkgfile"

    # Instalar no sistema
    fakeroot_cmd rsync -a "$DESTDIR"/ /

    # Registrar arquivos e dependências
    find "$DESTDIR" -type f | sed "s#^$DESTDIR##" > "$DB_DIR/$pkg.files"
    if [ "${#DEPENDS[@]}" -gt 0 ]; then
        printf "%s\n" "${DEPENDS[@]}" > "$DB_DIR/$pkg.deps"
    else
        : > "$DB_DIR/$pkg.deps"
    fi

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

    # Nome lógico do pacote a partir do arquivo (sem extensão)
    local pkg
    pkg=$(basename "$file" | sed 's/\.\(tar\.zst\|tar\.gz\|tar\.xz\)$//')

    find "$DESTDIR" -type f | sed "s#^$DESTDIR##" > "$DB_DIR/$pkg.files"
    : > "$DB_DIR/$pkg.deps"   # desconhecido para pacotes binários externos

    ok "pacote instalado: $pkg"
}

remove_pkg() {
    local pkg="$1"
    run_hooks pre_remove "$pkg"
    [ -f "$DB_DIR/$pkg.files" ] || err "não registrado: $pkg"

    log "removendo arquivos de $pkg"
    while read -r f; do
        [ -n "$f" ] || continue
        case "$f" in
            "$PREFIX"/*) fakeroot_cmd rm -vf "/$f" || true ;;
            *) warn "ignorado fora do PREFIX: $f" ;;
        esac
    done < "$DB_DIR/$pkg.files"

    rm -f "$DB_DIR/$pkg.files"

    # Remover dependências órfãs (recursivo)
    if [ -f "$DB_DIR/$pkg.deps" ]; then
        while read -r dep; do
            [ -n "$dep" ] || continue
            if [ -f "$DB_DIR/$dep.files" ]; then
                if ! dep_in_use_elsewhere "$dep" "$pkg"; then
                    log "dependência órfã detectada: $dep → removendo"
                    remove_pkg "$dep"
                else
                    log "dependência ainda em uso: $dep (mantendo)"
                fi
            fi
        done < "$DB_DIR/$pkg.deps"
        rm -f "$DB_DIR/$pkg.deps"
    fi

    run_hooks post_remove "$pkg"
    ok "removido: $pkg"
}

list_recipes() {
    shopt -s nullglob
    local arr=("$RECIPES_DIR"/*.recipe "$RECIPES_DIR"/*.sh)
    shopt -u nullglob
    if [ "${#arr[@]}" -eq 0 ]; then
        return 0
    fi
    printf "%s\n" "${arr[@]##*/}" | sed 's/\.\(recipe\|sh\)$//' | sort -u
}

list_installed() {
    shopt -s nullglob
    local arr=("$DB_DIR"/*.files)
    shopt -u nullglob
    [ "${#arr[@]}" -eq 0 ] && return 0
    printf "%s\n" "${arr[@]##*/}" | sed 's/\.files$//'
}

info_pkg() {
    local pkg="$1"
    load_recipe "$pkg"
    echo -e "${BLU}== $NAME $VERSION ==${RST}"
    echo "SRC: ${SRC_URI[*]}"
    echo "DEPENDS: ${DEPENDS[*]:-nenhum}"
    [ "${#PATCHES[@]:-0}" -gt 0 ] && echo "PATCHES: ${PATCHES[*]}"
}

sync_repo() {
    if [ -d "$RECIPES_DIR/.git" ]; then
        (cd "$RECIPES_DIR" && git pull && git add . && git commit -am "sync" && git push) || true
    fi
}

doctor() {
    local missing=0
    for tool in wget rsync git make fakeroot sha256sum tar patch; do
        if ! command -v "$tool" >/dev/null; then
            warn "falta: $tool"
            missing=1
        fi
    done
    # checar suporte ao zstd
    if ! command -v zstd >/dev/null; then
        warn "falta: zstd (recomendado para .tar.zst)"
        missing=1
    fi
    [ $missing -eq 0 ] && ok "tudo certo!"
}

usage() {
cat <<EOF
sourcelite — gerenciador source-based simples
uso: sourcelite <comando> [args]

comandos:
  new <nome>         cria recipe básica
  fetch <pkg>        baixa source
  build <pkg>        compila (resolve deps)
  makepkg <pkg>      compila e gera pacote (sem instalar)
  install <pkg>      instala e empacota (resolve deps)
  installpkg <arq>   instala direto de pacote .tar.zst/.tar.gz/.tar.xz
  remove <pkg>       remove (e remove dependências órfãs)
  list               lista recipes
  installed          lista instalados
  info <pkg>         mostra info da recipe
  sync               sincroniza git do diretório de recipes
  doctor             checa dependências do sistema
EOF
}

new_recipe() {
    local pkg="$1"
    [ -n "${pkg:-}" ] || err "uso: sourcelite new <nome>"
    cat > "$RECIPES_DIR/$pkg.recipe" <<'EOR'
# Exemplo de recipe
NAME="${NAME:-__PKG__}"
VERSION="1.0.0"
SRC_URI=("https://exemplo.com/${NAME}-${VERSION}.tar.gz")
SHA256=()   # opcional: ("<hash do primeiro tarball>")
PATCHES=()  # opcional: ("fix-build.patch")
DEPENDS=()  # ex: ("zlib" "openssl")

BUILD() {
  ./configure --prefix="$PREFIX"
  make -j"$JOBS"
}

INSTALL() {
  make DESTDIR="$DESTDIR" install
}
EOR
    # substituir placeholder
    sed -i "s/__PKG__/$pkg/g" "$RECIPES_DIR/$pkg.recipe"
    ok "recipe criada: $RECIPES_DIR/$pkg.recipe"
}

# =========================
# CLI
# =========================
cmd="${1:-help}"
case "$cmd" in
    new)        shift; new_recipe "${1:-}";;
    fetch)      shift; fetch "${1:-}";;
    build)      shift; build "${1:-}";;
    makepkg)    shift; makepkg "${1:-}";;
    install)    shift; install_pkg "${1:-}";;
    installpkg) shift; installpkg "${1:-}";;
    remove)     shift; remove_pkg "${1:-}";;
    list)       list_recipes;;
    installed)  list_installed;;
    info)       shift; info_pkg "${1:-}";;
    sync)       sync_repo;;
    doctor)     doctor;;
    help|--help|-h|"") usage;;
    *) err "comando desconhecido: $cmd";;
esac
