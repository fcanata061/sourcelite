#!/usr/bin/env bash



sourcelite

Um gerenciador de programas source-based simples para LFS/LfS-like.

- Recipes em Bash (apenas variáveis e funções) por pacote

- Patch, log, registro, hooks e sync com repositório Git de recipes

- Zero dependências além de: bash, coreutils, tar, patch, make, sha256sum, git (opcional para sync)



Licença: MIT



=== Layout padrão (override via .sourcelite.conf) ===

RECIPES_DIR  : ~/sourcelite/recipes

WORK_DIR     : ~/.local/share/sourcelite

SRC_DIR      : $WORK_DIR/src

BUILD_DIR    : $WORK_DIR/build

PKG_DIR      : $WORK_DIR/pkg  (destino de DESTDIR para install)

DB_DIR       : $WORK_DIR/db   (registro de pacotes instalados)

LOG_DIR      : $WORK_DIR/log

HOOKS_DIR    : $WORK_DIR/hooks (pre_/post_ subpastas)

PREFIX       : /usr/local (pode ser sobrescrito por recipe)



=== Formato de Recipe (recipes/<nome>.recipe ou .sh) ===

NAME="hello"

VERSION="2.12.1"

SRC_URI=("https://ftp.gnu.org/gnu/hello/hello-${VERSION}.tar.gz")

SHA256=("60fchecksum...")  # opcional; um por arquivo em SRC_URI

PATCHES=("hello-musl.patch")   # opcional; relativo à pasta da recipe

DEPENDS=("zlib" "gettext")     # opcional; informativo

CONFIGURE_FLAGS=("--prefix=${PREFIX}")

BUILD() { ./configure "${CONFIGURE_FLAGS[@]}" && make -j"${JOBS}"; }

INSTALL() { make DESTDIR="${DESTDIR}" install; }

POST_INSTALL() { :; }   # opcional

POST_REMOVE()  { :; }   # opcional



Variáveis utilitárias disponíveis na execução:

NAME VERSION SRC_DIR BUILD_DIR PKG_DIR WORK_DIR PREFIX DESTDIR JOBS RECIPE_DIR LOG_FILE

SOURCE_DIR (diretório do código extraído)



set -Eeuo pipefail shopt -s extglob

VERSION_SL="0.2.0" SELF_NAME="sourcelite"

==== Carregar config do usuário se existir ====

default_recipes_dir="$HOME/sourcelite/recipes" default_work_dir="$HOME/.local/share/sourcelite"

RECIPES_DIR="${RECIPES_DIR:-$default_recipes_dir}" WORK_DIR="${WORK_DIR:-$default_work_dir}" SRC_DIR="${SRC_DIR:-$WORK_DIR/src}" BUILD_ROOT="${BUILD_DIR:-$WORK_DIR/build}" PKG_ROOT="${PKG_DIR:-$WORK_DIR/pkg}" DB_DIR="${DB_DIR:-$WORK_DIR/db}" LOG_DIR="${LOG_DIR:-$WORK_DIR/log}" HOOKS_DIR="${HOOKS_DIR:-$WORK_DIR/hooks}" PREFIX="${PREFIX:-/usr/local}" JOBS="${JOBS:-$(nproc 2>/dev/null || echo 1)}" GIT_SYNC_STATE_DIR="${GIT_SYNC_STATE_DIR:-$WORK_DIR/state}"

mkdir -p "$RECIPES_DIR" "$SRC_DIR" "$BUILD_ROOT" "$PKG_ROOT" "$DB_DIR" "$LOG_DIR" "$HOOKS_DIR" "$GIT_SYNC_STATE_DIR" for d in pre_fetch pre_build pre_install pre_remove post_fetch post_build post_install post_remove; do mkdir -p "$HOOKS_DIR/$d" done

==== Utils ====

msg() { printf "\e[1;34m==>\e[0m %s\n" "$"; } warn() { printf "\e[1;33m==> aviso:\e[0m %s\n" "$"; } err() { printf "\e[1;31m==> erro:\e[0m %s\n" "$*" >&2; }

log() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$LOG_FILE"; }

run_hooks() { local phase="$1"; shift || true local dir="$HOOKS_DIR/$phase" if [[ -d "$dir" ]]; then while IFS= read -r -d '' hook; do if [[ -x "$hook" ]]; then log "HOOK $phase: $(basename "$hook")" "$hook" "$@" 2>&1 | tee -a "$LOG_FILE" fi done < <(find "$dir" -maxdepth 1 -type f -print0 | sort -z) fi }

require() { command -v "$1" >/dev/null || { err "comando obrigatório não encontrado: $1"; exit 1; }; }

sanitize() { sed 's/[^A-Za-z0-9.+-]//g' <<<"$1"; }

==== Registro simples ====

Cada pacote instalado possui: $DB_DIR/<name>/meta, files.list, manifest.json (opcional)

reg_pkg_dir() { echo "$DB_DIR/$(sanitize "$1")"; } reg_is_installed() { [[ -f "$(reg_pkg_dir "$1")/meta" ]]; } reg_write_meta() { local name="$1"; local version="$2"; local recipe="$3" local dir; dir="$(reg_pkg_dir "$name")"; mkdir -p "$dir" { echo "NAME=$name" echo "VERSION=$version" echo "RECIPE=$recipe" echo "DATE=$(date -u +%FT%TZ)" echo "PREFIX=$PREFIX" } >"$dir/meta" }

==== Recipe loader ====

Suporta .recipe ou .sh

find_recipe_file() { local name="$1" if [[ -f "$RECIPES_DIR/$name.recipe" ]]; then echo "$RECIPES_DIR/$name.recipe"; return; fi if [[ -f "$RECIPES_DIR/$name.sh" ]]; then echo "$RECIPES_DIR/$name.sh"; return; fi

procurar por nome exato insensitive

local match match=$(find "$RECIPES_DIR" -maxdepth 1 -type f  -printf "%f\n" | sed 's/..*$//' | awk -v n="$name" 'tolower($0)==tolower(n){print; exit}') || true if [[ -n "$match" && -f "$RECIPES_DIR/$match.recipe" ]]; then echo "$RECIPES_DIR/$match.recipe"; return; fi if [[ -n "$match" && -f "$RECIPES_DIR/$match.sh" ]]; then echo "$RECIPES_DIR/$match.sh"; return; fi return 1 }

load_recipe() { RECIPE_FILE="$1"; RECIPE_DIR="$(cd "$(dirname "$RECIPE_FILE")" && pwd)"

reset ambiente de recipe

unset NAME VERSION SRC_URI SHA256 PATCHES DEPENDS CONFIGURE_FLAGS unset -f BUILD INSTALL POST_INSTALL POST_REMOVE || true

shellcheck source=/dev/null

source "$RECIPE_FILE" : "${NAME:?Recipe precisa definir NAME}" : "${VERSION:?Recipe precisa definir VERSION}" : "${PREFIX:=${PREFIX}}" SRC_URI=("${SRC_URI[@]:-}") SHA256=("${SHA256[@]:-}") PATCHES=("${PATCHES[@]:-}") DEPENDS=("${DEPENDS[@]:-}") CONFIGURE_FLAGS=("${CONFIGURE_FLAGS[@]:-}") SAFE_NAME="$(sanitize "$NAME")" BUILD_DIR="$BUILD_ROOT/${SAFE_NAME}-${VERSION}" DESTDIR="$PKG_ROOT/${SAFE_NAME}-${VERSION}" LOG_FILE="$LOG_DIR/${SAFE_NAME}.log" }

==== Fetch & verify ====

fetch_sources() { run_hooks pre_fetch "$NAME" "$VERSION" mkdir -p "$SRC_DIR" "$BUILD_DIR" log "Baixando fontes: ${SRC_URI[]:-(nenhum)}" local i=0 for url in "${SRC_URI[@]:-}"; do local fname dest fname="${url##/}" dest="$SRC_DIR/$fname" if [[ ! -f "$dest" ]]; then require curl log "curl -L -o '$dest' '$url'" curl -fsSL -o "$dest" "$url" else log "já existe: $dest" fi if [[ -n "${SHA256[$i]:-}" ]]; then echo "${SHA256[$i]}  $dest" | sha256sum -c - | tee -a "$LOG_FILE" else warn "sem SHA256 para $fname (pulei verificação)" fi ((i++)) || true done run_hooks post_fetch "$NAME" "$VERSION" }

==== Unpack ====

unpack_sources() { log "Preparando diretório de build: $BUILD_DIR" rm -rf "$BUILD_DIR" "$DESTDIR" mkdir -p "$BUILD_DIR" "$DESTDIR" local first_src extracted_dir if [[ ${#SRC_URI[@]:-} -gt 0 ]]; then first_src="$SRC_DIR/${SRC_URI[0]##*/}" case "$first_src" in .tar.gz|.tgz) tar -xzf "$first_src" -C "$BUILD_DIR" ;; *.tar.bz2) tar -xjf "$first_src" -C "$BUILD_DIR" ;; *.tar.xz) tar -xJf "$first_src" -C "$BUILD_DIR" ;; *.zip) require unzip; unzip -q "$first_src" -d "$BUILD_DIR" ;; *) # Se não for um tar conhecido, apenas copiar tudo cp -f "$first_src" "$BUILD_DIR/" ;; esac # Pick diretório fonte (primeiro que contiver configure ou Makefile) extracted_dir=$(find "$BUILD_DIR" -mindepth 1 -maxdepth 1 -type d | head -n1) SOURCE_DIR="${extracted_dir:-$BUILD_DIR}" else SOURCE_DIR="$BUILD_DIR" # recipes sem fontes (metapacotes) fi log "SOURCE_DIR=$SOURCE_DIR" }

apply_patches() { if [[ ${#PATCHES[@]:-} -eq 0 ]]; then return; fi pushd "$SOURCE_DIR" >/dev/null for p in "${PATCHES[@]}"; do local patch_path="$RECIPE_DIR/$p" [[ -f "$patch_path" ]] || { err "patch não encontrado: $patch_path"; exit 1; } log "Aplicando patch: $p" patch -p1 < "$patch_path" 2>&1 | tee -a "$LOG_FILE" done popd >/dev/null }

==== Build / Install ====

default_build() { pushd "$SOURCE_DIR" >/dev/null if [[ -x ./configure ]]; then ./configure --prefix="$PREFIX" "${CONFIGURE_FLAGS[@]:-}" 2>&1 | tee -a "$LOG_FILE" fi make -j"$JOBS" 2>&1 | tee -a "$LOG_FILE" popd >/dev/null }

default_install() { pushd "$SOURCE_DIR" >/dev/null if grep -qE "^install:" Makefile 2>/dev/null || make -n install >/dev/null 2>&1; then make DESTDIR="$DESTDIR" install 2>&1 | tee -a "$LOG_FILE" else # cópia básica se não houver alvo install mkdir -p "$DESTDIR/$PREFIX" && cp -r . "$DESTDIR/$PREFIX/src-${SAFE_NAME}-${VERSION}" fi popd >/dev/null }

build_package() { run_hooks pre_build "$NAME" "$VERSION" if declare -F BUILD >/dev/null; then BUILD 2>&1 | tee -a "$LOG_FILE"; else default_build; fi run_hooks post_build "$NAME" "$VERSION" }

install_package() { run_hooks pre_install "$NAME" "$VERSION" if declare -F INSTALL >/dev/null; then INSTALL 2>&1 | tee -a "$LOG_FILE"; else default_install; fi

Gerar lista de arquivos e registrar

local listfile pkgdir pkgdir="$DESTDIR" listfile="$(reg_pkg_dir "$NAME")/files.list" mkdir -p "$(dirname "$listfile")" (cd "$pkgdir" && find . -type f -o -type l -o -type d | sed 's/^.///') >"$listfile" reg_write_meta "$NAME" "$VERSION" "$RECIPE_FILE"

Instalar no sistema (rsync para /)

require rsync rsync -aH --info=progress2 "$pkgdir"/ /

Hook pós install

if declare -F POST_INSTALL >/dev/null; then POST_INSTALL 2>&1 | tee -a "$LOG_FILE"; fi run_hooks post_install "$NAME" "$VERSION" log "INSTALADO: $NAME-$VERSION em $PREFIX" }

remove_package() { run_hooks pre_remove "$NAME" "$VERSION" local dir; dir="$(reg_pkg_dir "$NAME")" if [[ ! -d "$dir" ]]; then err "não instalado: $NAME"; exit 1; fi local files="$dir/files.list" if [[ -f "$files" ]]; then while IFS= read -r f; do local path="/$f" if [[ -e "$path" || -L "$path" ]]; then rm -rf "$path"; fi done < "$files" fi if declare -F POST_REMOVE >/dev/null; then POST_REMOVE 2>&1 | tee -a "$LOG_FILE"; fi run_hooks post_remove "$NAME" "$VERSION" rm -rf "$dir" log "REMOVIDO: $NAME" }

==== Git sync (recipes + estado opcional) ====

git_sync() { if [[ ! -d "$RECIPES_DIR/.git" ]]; then warn "RECIPES_DIR não é um repositório git: $RECIPES_DIR" return 0 fi (cd "$RECIPES_DIR" && git pull --rebase || true)

Comitar estado (db e logs) se o estado for parte do mesmo repo via subdir state/

if [[ -d "$RECIPES_DIR/.git" ]]; then mkdir -p "$GIT_SYNC_STATE_DIR" rsync -a "$DB_DIR/" "$GIT_SYNC_STATE_DIR/db/" 2>/dev/null || true rsync -a "$LOG_DIR/" "$GIT_SYNC_STATE_DIR/log/" 2>/dev/null || true (cd "$RECIPES_DIR" && 
mkdir -p state && rsync -a "$GIT_SYNC_STATE_DIR"/ state/ && 
git add -A state && 
git commit -m "${SELF_NAME}: atualizar estado $(date -u +%F)" || true && 
git push || true) fi }

==== CLI ====

usage() { cat <<EOF $SELF_NAME v$VERSION_SL — gerenciador source-based simples

Uso: $SELF_NAME <comando> [args]

Comandos: new <nome>               Cria recipe template em $RECIPES_DIR fetch <nome>             Baixa fontes e verifica checksum build <nome>             Baixa, extrai, aplica patches e compila install <nome>           Idem build e instala no sistema (rsync /) remove <nome>            Remove arquivos instalados via registro info <nome>              Mostra info da recipe e estado list                     Lista recipes disponíveis installed                Lista pacotes instalados search <padrão>          Busca por recipes por nome log <nome>               Abre/mostra log do pacote clean <nome|all>         Limpa diretórios de build/pkg sync                     Sincroniza recipes/estado com Git doctor                   Verifica dependências externas

Variáveis úteis (override via env ou no recipe): RECIPES_DIR WORK_DIR SRC_DIR BUILD_DIR PKG_DIR DB_DIR LOG_DIR HOOKS_DIR PREFIX JOBS

Exemplos: $SELF_NAME new hello $SELF_NAME build hello && $SELF_NAME install hello PREFIX=/usr $SELF_NAME install hello EOF }

cmd_new() { local name="$1"; local file="$RECIPES_DIR/$(sanitize "$name").recipe" mkdir -p "$RECIPES_DIR" if [[ -e "$file" ]]; then err "já existe: $file"; exit 1; fi cat >"$file" <<'TPL'

Recipe template para sourcelite

NAME="hello" VERSION="2.12.1" SRC_URI=("https://ftp.gnu.org/gnu/hello/hello-${VERSION}.tar.gz") SHA256=("8bd4f8a7bc96a0f6a1f8c7a2f3e8f4c85d1a1b9b3a2d4c17c7b3d2f2c5a0e5a1") PATCHES=( ) DEPENDS=( ) CONFIGURE_FLAGS=("--prefix=${PREFIX}")

BUILD() { ./configure "${CONFIGURE_FLAGS[@]}" make -j"${JOBS}" }

INSTALL() { make DESTDIR="${DESTDIR}" install } TPL msg "recipe criada: $file" }

cmd_fetch() { load_recipe_file "$1"; fetch_sources; }

cmd_build() { load_recipe_file "$1"; fetch_sources; unpack_sources; apply_patches; build_package; }

cmd_install() { load_recipe_file "$1"; fetch_sources; unpack_sources; apply_patches; build_package; install_package; }

cmd_remove() { load_recipe_file "$1"; remove_package; }

cmd_info() { load_recipe_file "$1" echo "Recipe: $RECIPE_FILE" echo "NAME=$NAME VERSION=$VERSION PREFIX=$PREFIX" echo "SRC_URI=${SRC_URI[]:-}" echo "PATCHES=${PATCHES[]:-}" echo "DEPENDS=${DEPENDS[*]:-}" if reg_is_installed "$NAME"; then echo "Status: INSTALADO" cat "$(reg_pkg_dir "$NAME")/meta" else echo "Status: não instalado" fi }

cmd_list() { find "$RECIPES_DIR" -maxdepth 1 -type f  -printf "%f\n" | sed 's/..*$//' | sort; }

cmd_installed() { find "$DB_DIR" -mindepth 1 -maxdepth 1 -type d -printf "%f\n" | sort; }

cmd_search() { local pat="$1"; cmd_list | grep -i -- "$pat" || true; }

cmd_log() { load_recipe_file "$1"; : >"$LOG_FILE"; ${PAGER:-less} "$LOG_FILE" 2>/dev/null || cat "$LOG_FILE"; }

cmd_clean() { if [[ "${1:-}" == "all" ]]; then rm -rf "$BUILD_ROOT" "$PKG_ROOT" msg "limpo: build e pkg" else load_recipe_file "$1" rm -rf "$BUILD_DIR" "$DESTDIR" msg "limpo: $NAME" fi }

cmd_sync() { git_sync; }

cmd_doctor() { local req=(curl tar patch make sha256sum rsync) local missing=() for c in "${req[@]}"; do command -v "$c" >/dev/null || missing+=("$c"); done if (( ${#missing[@]} > 0 )); then err "Faltando comandos: ${missing[*]}" exit 1 else msg "Ambiente OK" fi }

load_recipe_file() { local name="$1"; [[ -n "$name" ]] || { err "informe o nome do pacote"; exit 1; } local rf rf=$(find_recipe_file "$name") || { err "recipe não encontrada para '$name' em $RECIPES_DIR"; exit 1; } load_recipe "$rf" }

main() { if (( $# < 1 )); then usage; exit 1; fi local cmd="$1"; shift case "$cmd" in -h|--help|help) usage ;; -v|--version) echo "$SELF_NAME $VERSION_SL" ;; new) cmd_new "${1:?faltou nome}" ;; fetch) cmd_fetch "${1:?faltou nome}" ;; build) cmd_build "${1:?faltou nome}" ;; install) cmd_install "${1:?faltou nome}" ;; remove) cmd_remove "${1:?faltou nome}" ;; info) cmd_info "${1:?faltou nome}" ;; list) cmd_list ;; installed) cmd_installed ;; search) cmd_search "${1:?faltou padrão}" ;; log) cmd_log "${1:?faltou nome}" ;; clean) cmd_clean "${1:-all}" ;; sync) cmd_sync ;; doctor) cmd_doctor ;; *) err "comando desconhecido: $cmd"; usage; exit 1 ;; esac }

main "$@"

