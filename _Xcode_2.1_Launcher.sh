#!/bin/bash
#
# 
set -u
set -o pipefail
umask 077

DIALOG="/usr/local/bin/dialog"
JAMF_BIN="/usr/local/bin/jamf"
BASE_DIR="/Applications"
XCODE_APP="/Applications/Xcode.app"
ICON_URL="https://usw2.ics.services.jamfcloud.com/icon/hash_34643aa5722dd94f45ffd8102dd67e8fb135eede6a855c578a9c9b866b543cc6"
SCRIPT_LOG="/var/log/bra_xcode_manager.log"
FIX_BASE="/Library/Application Support/SantanderFiles/Jamf/BR_Fix_Xcode"
SUPPORT_LOG="$FIX_BASE/gerenciador_xcode.log"
STATE_DIR="/Library/Application Support/SantanderFiles/Jamf/XcodeManager"
LOCK_DIR="$STATE_DIR/.manager.lock"
BACKUP_PLIST="$STATE_DIR/Info.plist.original.pending"
BACKUP_INODE="$STATE_DIR/Info.plist.original.inode"
PROGRESS_FILE=""
PROGRESS_PID=""
PROGRESS_LOG="/Library/Application Support/SantanderFiles/Jamf/XcodeManager/dialog_progresso_ultimo.log"
WARNING_FILE=""
WARNING_PID=""
LOCK_OWNED=0
FIX_SWAP_ACTIVE=0
REPAIR_BACKUPS="$FIX_BASE/Backups"
CONSOLE_USER=""
CONSOLE_UID=""
SELECTION_MODE=""  # installed / install
FIX_OUTCOME="not_attempted"
INTEGRITY_OUTCOME="not_checked"
# O --deep verifica tambem frameworks aninhados e torna a selecao muito lenta.
# 'fast' valida a assinatura e os recursos do bundle principal; 'deep' (opcional)
# tambem percorre os binarios internos. Escolha 'deep' para auditoria/homologacao.
SIGNATURE_VERIFY_MODE="fast"
# 'on_failure' (padrao): nao repetir codesign apos restauracao bem-sucedida;
#                     executar diagnostico profundo somente se a restauracao ou SHA falhar.
# 'always': valida codesign novamente apos restauracao (auditoria/homologacao).
POST_RESTORE_CODESIGN_MODE="on_failure"
# Temporario para homologacao: desligar/remover depois dos testes.
AUDIT_ENABLED=1
AUDIT_LOG="$STATE_DIR/diagnostico_xcode_3_7.log"
AUDIT_SESSION="$(/bin/date '+%Y%m%d_%H%M%S')_$$"
# 1 apenas para testes da primeira instalacao: nao alterar em producao.
PREOPEN_ORIGINAL_ON_INSTALL=1
PREOPEN_ORIGINAL_OUTCOME="not_attempted"
FIX_OPEN_BLOCKED_EXPECTED=0


# Preservar os mesmos triggers do Gerenciador Xcode V2 anexado.
XCODE_VERSIONS=(
    "Xcode 16.4:Xcode16.4"
    "Xcode 26.3:Xcode26.3"
    "Xcode 26.5:Xcode26.5"
    "Xcode 26.6:Xcode26.6"
    "Xcode 27.0:Ofc_Xcode27"
)

log() {
    local msg="$(/bin/date '+%Y-%m-%d %H:%M:%S') [XcodeManager] $*"
    /bin/echo "$msg" >> "$SCRIPT_LOG"
    [ -f "$SUPPORT_LOG" ] && /bin/echo "$msg" >> "$SUPPORT_LOG"
    return 0
}

# Log independente, sem stdout do Jamf (pode conter URLs/tokens corporativos).
# Apenas informacoes tecnicas: versao/build, inode, hashes, etapa e codigo de retorno.
audit() {
    [ "$AUDIT_ENABLED" = 1 ] || return 0
    [ -n "$AUDIT_LOG" ] || return 0
    /usr/bin/printf '%s [DIAG37 session=%s] %s\n' \
        "$(/bin/date '+%Y-%m-%d %H:%M:%S%z')" "$AUDIT_SESSION" "$*" \
        >> "$AUDIT_LOG" 2>/dev/null || true
    return 0
}

audit_init() {
    [ "$AUDIT_ENABLED" = 1 ] || return 0
    /usr/bin/touch "$AUDIT_LOG" 2>/dev/null || return 0
    /usr/sbin/chown root:admin "$AUDIT_LOG" 2>/dev/null || true
    /bin/chmod 640 "$AUDIT_LOG" 2>/dev/null || true
    grant_read_access "$AUDIT_LOG" file || true
    audit "=== INICIO os=$(/usr/bin/sw_vers -productVersion 2>/dev/null) user=$CONSOLE_USER uid=$CONSOLE_UID script_pid=$$ ==="
    audit "VERSAO_BASE=3.7; EXPERIMENTO_PRE_ABERTURA_ORIGINAL=sim; preopen_ativado=$PREOPEN_ORIGINAL_ON_INSTALL; diagnostico=$AUDIT_LOG"
    log "DIAG37_ATIVO: arquivo=$AUDIT_LOG; session=$AUDIT_SESSION"
}

# Nao invoca codesign/LaunchServices nem modifica o app.
# Comparacao APP + demais Xcode*.app antes/depois de instalar e alternar.
audit_snapshot() {
    [ "$AUDIT_ENABLED" = 1 ] || return 0
    local tag="$1" app plist ver build bundle appid astat pstat phash attrs active xselect
    audit "SNAPSHOT_INICIO tag=$tag mode=${SELECTION_MODE:-unknown}"
    xselect=$(/usr/bin/xcode-select -p 2>/dev/null || /bin/echo unavailable)
    audit "XCODE_SELECT path=$xselect"
    if other_xcode_running; then active="yes"; else active="no"; fi
    audit "XCODE_EXECUTANDO_CONSOLE=$active"
    for app in "$XCODE_APP" "$BASE_DIR"/Xcode_*.app; do
        [ -d "$app" ] || continue
        plist="$app/Contents/Info.plist"
        ver=$(get_plist_value "$plist" CFBundleShortVersionString 2>/dev/null || true)
        build=$(get_plist_value "$plist" CFBundleVersion 2>/dev/null || true)
        bundle=$(get_plist_value "$plist" CFBundleIdentifier 2>/dev/null || true)
        appid=$(/usr/bin/stat -f '%i' "$app" 2>/dev/null || /bin/echo unavailable)
        astat=$(/usr/bin/stat -f 'birth=%B mtime=%m' "$app" 2>/dev/null || /bin/echo unavailable)
        pstat=$(/usr/bin/stat -f 'inode=%i mtime=%m' "$plist" 2>/dev/null || /bin/echo unavailable)
        if [ -f "$plist" ]; then
            phash=$(sha256 "$plist" 2>/dev/null || /bin/echo unavailable)
        else
            phash=absent
        fi
        # Somente NOMES dos xattrs; valores podem conter metadados privados.
        attrs=$(/usr/bin/xattr "$app" 2>/dev/null | /usr/bin/tr '\n' ',' || true)
        audit "APP path=$app app_inode=$appid $astat version=$ver build=$build bundle=$bundle plist_$pstat plist_sha256=$phash xattr_names=${attrs:-none}"
    done
    [ -e "$BACKUP_PLIST" ] && audit "BACKUP_PENDENTE=yes hash=$(sha256 "$BACKUP_PLIST" 2>/dev/null || /bin/echo unavailable) inode_esperado=$(/bin/cat "$BACKUP_INODE" 2>/dev/null || true)"
    [ ! -e "$BACKUP_PLIST" ] && audit "BACKUP_PENDENTE=no"
    audit "SNAPSHOT_FIM tag=$tag"
    return 0
}

# Somente ACL de leitura: mantem as permissoes de escrita com root/Jamf.
# macOS: /bin/chmod +a "usuario allow list,search,..." diretorio
# Evita adicionar entradas duplicadas a cada execucao da politica.
grant_read_access() {
    local path="$1" kind="$2" rights
    [ -e "$path" ] || return 1
    case "$CONSOLE_USER" in
        ""|root|loginwindow|_mbsetupuser) return 1 ;;
    esac
    if /bin/ls -lde "$path" 2>/dev/null | /usr/bin/grep -F "${CONSOLE_USER} allow " >/dev/null; then
        return 0
    fi
    if [ "$kind" = "dir" ]; then
        rights="list,search,readattr,readextattr,readsecurity"
    else
        rights="read,readattr,readextattr,readsecurity"
    fi
    /bin/chmod +a "${CONSOLE_USER} allow ${rights}" "$path" 2>/dev/null
}

# Inicializa diretorios e logs sob root, sem abrir permissao de escrita para users.
prepare_support_paths() {
    /bin/mkdir -p "$STATE_DIR" "$REPAIR_BACKUPS" || return 1
    /bin/chmod 750 "$STATE_DIR" "$REPAIR_BACKUPS" "$FIX_BASE" || return 1
    /usr/sbin/chown root:admin "$STATE_DIR" "$REPAIR_BACKUPS" "$FIX_BASE" 2>/dev/null || true
    /usr/bin/touch "$SCRIPT_LOG" "$SUPPORT_LOG" || return 1
    /bin/chmod 640 "$SCRIPT_LOG" "$SUPPORT_LOG" || return 1
    /usr/sbin/chown root:admin "$SCRIPT_LOG" "$SUPPORT_LOG" 2>/dev/null || true
    return 0
}

# Permissao de LEITURA para o proprio usuario que executou via interface Jamf.
# Os diretorios pais recebem somente traverse/list, nao escrita nem leitura
# recursiva dos demais arquivos corporativos em SantanderFiles.
prepare_console_read_access() {
    local d file
    for d in \
        "/Library/Application Support/SantanderFiles" \
        "/Library/Application Support/SantanderFiles/Jamf" \
        "$FIX_BASE" "$REPAIR_BACKUPS" "$STATE_DIR"; do
        if ! grant_read_access "$d" dir; then
            log "AVISO_ACL: impossivel conceder leitura para $CONSOLE_USER em $d"
        fi
    done
    for file in "$SCRIPT_LOG" "$SUPPORT_LOG"; do
        if ! grant_read_access "$file" file; then
            log "AVISO_ACL: impossivel conceder leitura para $CONSOLE_USER em $file"
        fi
    done
    # Os backups preexistentes sao mantidos; leitura so dos arquivos
    # especificamente gerados pelo fix, sem alterar suas permissoes globais.
    shopt -s nullglob
    for file in "$REPAIR_BACKUPS"/Xcode_*_Info.plist_*.bak "$REPAIR_BACKUPS"/Xcode_*_FinderInfo_*.hex; do
        grant_read_access "$file" file || true
    done
    shopt -u nullglob
}

preserve_backup_access() {
    local file="$1"
    /usr/sbin/chown root:admin "$file" 2>/dev/null || true
    /bin/chmod 640 "$file" 2>/dev/null || true
    grant_read_access "$file" file || true
}

get_plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null
}

app_version() {
    [ -f "$1/Contents/Info.plist" ] || return 1
    get_plist_value "$1/Contents/Info.plist" CFBundleShortVersionString
}

app_valid() {
    [ -d "$1" ] && [ -x "$1/Contents/MacOS/Xcode" ] && \
        [ "$(get_plist_value "$1/Contents/Info.plist" CFBundleIdentifier)" = "com.apple.dt.Xcode" ]
}

version_major() {
    local value="${1%%.*}"
    [[ "$value" =~ ^[0-9]+$ ]] || return 1
    /bin/echo "$((10#$value))"
}

# Permite ordenar 27.2 > 27.1 sem depender de sort -V (nao presente em todo macOS).
version_key() {
    local clean="${1%% *}" a=0 b=0 c=0 d=0
    IFS=. read -r a b c d <<< "$clean"
    [[ "$a" =~ ^[0-9]+$ ]] || return 1
    [[ "$b" =~ ^[0-9]+$ ]] || b=0
    [[ "$c" =~ ^[0-9]+$ ]] || c=0
    [[ "$d" =~ ^[0-9]+$ ]] || d=0
    /usr/bin/printf '%04d%04d%04d%04d' "$((10#$a))" "$((10#$b))" "$((10#$c))" "$((10#$d))"
}

sha256() {
    /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

app_inode() {
    /usr/bin/stat -f '%i' "$1" 2>/dev/null
}

progress_cmd() {
    # Jamf/root escreve comandos; swiftDialog, iniciado na sessao grafica,
    # precisa conseguir LER o mesmo arquivo. Nunca falhar a politica so
    # porque a janela de progresso nao esta disponivel.
    if [ -n "$PROGRESS_FILE" ] && [ -f "$PROGRESS_FILE" ]; then
        /bin/echo "$*" >> "$PROGRESS_FILE" 2>/dev/null || \
            log "AVISO_PROGRESSO: falha ao escrever no commandfile"
    fi
    return 0
}

progress_start() {
    local status=0 line

    # mktemp cria o arquivo com 0600, normalmente pertencente a root.
    # O launcher de swiftDialog pode abrir a janela no contexto do usuario
    # grafico; corrigir as permissoes ANTES de inicializar a interface.
    PROGRESS_FILE=$(/usr/bin/mktemp /var/tmp/bra_xcode_progress.XXXXXX) || {
        log "AVISO_PROGRESSO: falha ao criar commandfile"
        return 1
    }
    if ! /usr/sbin/chown "$CONSOLE_USER" "$PROGRESS_FILE" || \
       ! /bin/chmod 600 "$PROGRESS_FILE" || \
       ! /usr/bin/sudo -u "$CONSOLE_USER" /bin/test -r "$PROGRESS_FILE"; then
        log "AVISO_PROGRESSO: $CONSOLE_USER nao consegue ler o commandfile"
        /bin/rm -f "$PROGRESS_FILE"
        PROGRESS_FILE=""
        return 1
    fi

    # Diagnostico legivel pelo usuario, sem conceder escrita fora do root.
    /usr/bin/touch "$PROGRESS_LOG" || {
        log "AVISO_PROGRESSO: impossivel criar $PROGRESS_LOG"
        /bin/rm -f "$PROGRESS_FILE"
        PROGRESS_FILE=""
        return 1
    }
    /usr/sbin/chown root:admin "$PROGRESS_LOG" 2>/dev/null || true
    /bin/chmod 640 "$PROGRESS_LOG" 2>/dev/null || true
    grant_read_access "$PROGRESS_LOG" file || true
    : > "$PROGRESS_LOG"

    # --progress sem numero indica progresso indeterminado (Jamf nao informa
    # uma porcentagem confiavel do download em todos os cenarios).
    "$DIALOG" --mini --title "Gerenciador Xcode" --icon "$ICON_URL" \
        --message "Instalando o Xcode selecionado. Aguarde..." \
        --progresstext "Iniciando instalacao via Jamf..." \
        --progress --ontop --moveable --position bottomright \
        --commandfile "$PROGRESS_FILE" > "$PROGRESS_LOG" 2>&1 &
    PROGRESS_PID=$!
    /bin/sleep 0.3

    # Antes a saida do dialog era descartada; agora falhas podem ser
    # diagnosticadas sem afetar a instalacao do pacote.
    if ! /bin/kill -0 "$PROGRESS_PID" 2>/dev/null; then
        wait "$PROGRESS_PID" || status=$?
        log "AVISO_PROGRESSO: SwiftDialog encerrou no inicio (status $status)"
        if [ -s "$PROGRESS_LOG" ]; then
            while IFS= read -r line; do
                log "PROGRESSO_SWIFTDIALOG: ${line:0:250}"
            done < <(/usr/bin/tail -n 12 "$PROGRESS_LOG")
        fi
        /bin/rm -f "$PROGRESS_FILE"
        PROGRESS_FILE=""
        PROGRESS_PID=""
        return 1
    fi
    log "PROGRESSO: janela de instalacao iniciada; commandfile legivel por $CONSOLE_USER"
    return 0
}

progress_stop() {
    if [ -n "$PROGRESS_FILE" ]; then
        progress_cmd "quit:"
        # Evitar deixar janela orfa em caso de falha no launcher.
        /bin/sleep 0.5
        if [ -n "$PROGRESS_PID" ] && /bin/kill -0 "$PROGRESS_PID" 2>/dev/null; then
            /bin/kill -TERM "$PROGRESS_PID" 2>/dev/null || true
            wait "$PROGRESS_PID" 2>/dev/null || true
        fi
        /bin/rm -f "$PROGRESS_FILE"
        PROGRESS_FILE=""
    fi
    PROGRESS_PID=""
}

show_error() {
    log "ERRO: $*"
    progress_stop
    "$DIALOG" --title "Gerenciador Xcode — Erro" --icon "$ICON_URL" \
        --overlayicon caution --message "$*" --button1text "OK" \
        --width 600 --height 280 --ontop >/dev/null 2>&1 || true
}

# Janelas da interface V2: somente eventos de gerenciamento (nao o fix).
show_rename_dialog() {
    local old_version="$1" operation="$2" title="Alterando Versão do Xcode" message
    if [ "$operation" = "install" ]; then
        title="Renomeando Xcode existente"
        message="Já existe uma versão do Xcode instalada.\n\nEla será renomeada para:\n\n**Xcode_${old_version}.app**\n\nEssa alteração permitirá o uso de múltiplas versões do Xcode no macOS."
    else
        message="A versão atual do Xcode será renomeada para:\n\n**Xcode_${old_version}.app**"
    fi
    "$DIALOG" --title "$title" --message "$message" --icon "$ICON_URL" \
        --button1text "Ok" --width 600 --height 300 --moveable --ontop \
        >/dev/null 2>&1
}

show_success_dialog() {
    local version="$1"
    "$DIALOG" --title "Sucesso" --icon "$ICON_URL" \
        --message "O Xcode.app localizado na pasta Aplicativos do seu Mac agora está definido para a versão Xcode $version" \
        --width 600 --height 300 --button1text "OK" --moveable --ontop \
        >/dev/null 2>&1 || true
}

# Mantem o progresso visivel do V2, mas sem aguardar indefinidamente por texto do jamf.log.
run_jamf_with_progress() {
    local trigger="$1" line clean
    set -o pipefail
    audit "JAMF_TRIGGER_INICIO trigger=$trigger"
    "$JAMF_BIN" policy -event "$trigger" 2>&1 | while IFS= read -r line; do
        log "JamfPolicy: $line"
        case "$line" in
            *"Successfully installed"*) audit "JAMF_PKG_INSTALADO" ;;
            *"Verifying package integrity"*) audit "JAMF_PKG_INTEGRIDADE" ;;
            *"Installing BRA_Xcode"*) audit "JAMF_INSTALANDO_PKG" ;;
            *"Running command"*) audit "JAMF_POS_INSTALL_COMANDO_INICIO" ;;
            *"Result of command"*) audit "JAMF_POS_INSTALL_COMANDO_FIM" ;;
            *"Submitting log"*) audit "JAMF_ENVIO_LOG" ;;
        esac
        case "$line" in
            *Downloading*|*Installing*|*Running\ script*|*Executing*|*Checking*|*Success*|*Error*|*error*|*failed*)
                clean="${line//$'\r'/ }"
                progress_cmd "progresstext: ${clean:0:170}"
                progress_cmd "progress: increment"
                ;;
        esac
    done
}

# Restaura de um backup permanente, inclusive apos crash/SIGKILL/reboot.
# Para evitar corromper outro Xcode, so restaura se o inode do app for o mesmo.
restore_pending_plist() {
    [ -f "$BACKUP_PLIST" ] || return 0
    local expected current expected_hash actual_hash
    expected=$(/bin/cat "$BACKUP_INODE" 2>/dev/null || true)
    current=$(app_inode "$XCODE_APP")
    if [ -z "$expected" ] || [ -z "$current" ] || [ "$expected" != "$current" ]; then
        log "ERRO: backup pendente, mas Xcode.app mudou. Preservando $BACKUP_PLIST para recuperacao manual."
        return 1
    fi
    expected_hash=$(sha256 "$BACKUP_PLIST") || return 1
    if ! /bin/cp -p "$BACKUP_PLIST" "$XCODE_APP/Contents/Info.plist"; then
        log "ERRO: falha na restauracao do Info.plist"
        return 1
    fi
    actual_hash=$(sha256 "$XCODE_APP/Contents/Info.plist") || return 1
    if [ "$expected_hash" != "$actual_hash" ]; then
        log "ERRO: SHA-256 divergiu apos restauracao"
        return 1
    fi
    /bin/rm -f "$BACKUP_PLIST" "$BACKUP_INODE"
    FIX_SWAP_ACTIVE=0
    log "Info.plist original restaurado (SHA-256: $actual_hash)"
    return 0
}


# No modo fast valida o bundle principal; --deep fica disponivel para
# auditoria e nao eh executado duas vezes em cada simples troca de versao.
verify_signature() {
    local verify_log
    local args=(--verify --strict)
    if [ "$SIGNATURE_VERIFY_MODE" = "deep" ]; then
        args=(--verify --deep --strict)
    fi
    verify_log=$(/usr/bin/mktemp "$STATE_DIR/xcode_verify.XXXXXX") || return 1
    if /usr/bin/codesign "${args[@]}" "$XCODE_APP" > "$verify_log" 2>&1; then
        /bin/rm -f "$verify_log"
        return 0
    fi
    log "codesign ${args[*]} falhou:"
    /usr/bin/tail -n 12 "$verify_log" >> "$SCRIPT_LOG"
    /bin/rm -f "$verify_log"
    return 1
}

# Diagnostico de excecao: restauracao, SHA-256 ou auditoria pos-fix falhar.
# Nao tenta alterar a instalacao, reassinar nem remover backup pendente.
post_restore_signature_diagnostic() {
    local diagfile rc=0
    diagfile=$(/usr/bin/mktemp "$STATE_DIR/xcode_post_restore.XXXXXX") || {
        log "CRITICO: nao foi possivel criar arquivo de diagnostico pos-restauracao"
        return 1
    }
    log "DIAGNOSTICO_POS_RESTAURACAO: verificacao profunda (somente em falha)"
    if ! /usr/bin/codesign --verify --deep --strict --verbose=2 "$XCODE_APP" > "$diagfile" 2>&1; then
        rc=1
        log "DIAGNOSTICO_POS_RESTAURACAO: codesign detectou falha; veja detalhes abaixo"
    else
        log "DIAGNOSTICO_POS_RESTAURACAO: assinatura valida, mas houve falha na restauracao/hash"
    fi
    /usr/bin/tail -n 20 "$diagfile" >> "$SCRIPT_LOG"
    /usr/bin/tail -n 20 "$diagfile" >> "$SUPPORT_LOG"
    /bin/rm -f "$diagfile"
    return "$rc"
}

# Guarda metadados externos sem criar arquivos adicionais no bundle assinado.
prepare_repair_dir() {
    /bin/mkdir -p "$REPAIR_BACKUPS" || return 1
    /bin/chmod 750 "$REPAIR_BACKUPS" || return 1
}

# Recupera especificamente o .bak antigo quando identico ao plist atual.
# Se a assinatura continuar invalida, faz rollback sem sobrescrever o plist.
repair_legacy_plist_backup() {
    local original="$XCODE_APP/Contents/Info.plist"
    local old_backup="$XCODE_APP/Contents/Info.plist.bak"
    local version="$1" destination
    [ -f "$old_backup" ] || return 1
    if ! /usr/bin/cmp -s "$original" "$old_backup"; then
        log "Info.plist.bak encontrado mas difere do original. Nao sera movido automaticamente."
        return 1
    fi
    prepare_repair_dir || { log "Falha ao preparar diretorio de backups"; return 1; }
    destination="$REPAIR_BACKUPS/Xcode_${version}_Info.plist_$(/bin/date +%Y%m%d_%H%M%S)_$$.bak"
    [ ! -e "$destination" ] || return 1
    if ! /bin/mv "$old_backup" "$destination"; then
        log "Nao foi possivel preservar o backup legado fora do bundle"
        return 1
    fi
    preserve_backup_access "$destination"
    log "Backup legado IDENTICO movido para $destination"
    if verify_signature; then
        log "Assinatura recuperada apos retirar backup legado do bundle Xcode $version"
        return 0
    fi
    log "Assinatura permanece invalida; restaurando backup legado anterior"
    if ! /bin/mv "$destination" "$old_backup"; then
        log "CRITICO: rollback do backup legado falhou. Backup preservado em $destination"
    fi
    return 1
}

# Remove especificamente FinderInfo da raiz se esta for a causa diagnosticada.
# Armazena o atributo em hexadecimal fora do .app para possibilitar rollback.
repair_finderinfo_root() {
    local version="$1" saved hex
    prepare_repair_dir || return 1
    saved="$REPAIR_BACKUPS/Xcode_${version}_FinderInfo_$(/bin/date +%Y%m%d_%H%M%S)_$$.hex"
    if ! /usr/bin/xattr -px com.apple.FinderInfo "$XCODE_APP" > "$saved" 2>/dev/null; then
        /bin/rm -f "$saved"
        log "FinderInfo ausente ou impossivel de copiar; nada alterado"
        return 1
    fi
    hex=$(/usr/bin/tr -d '[:space:]' < "$saved")
    if [[ ! "$hex" =~ ^[0-9a-fA-F]+$ ]] || [ $((${#hex} % 2)) -ne 0 ]; then
        log "FinderInfo nao possui representacao hexadecimal valida; abortando"
        /bin/rm -f "$saved"
        return 1
    fi
    if ! /usr/bin/xattr -d com.apple.FinderInfo "$XCODE_APP"; then
        log "Nao foi possivel remover com.apple.FinderInfo da raiz"
        return 1
    fi
    preserve_backup_access "$saved"
    log "com.apple.FinderInfo removido SOMENTE da raiz; copia em $saved"
    if verify_signature; then
        log "Assinatura recuperada apos remocao controlada de FinderInfo: Xcode $version"
        return 0
    fi
    log "Assinatura ainda invalida; revertendo atributo FinderInfo anterior"
    if ! /usr/bin/xattr -wx com.apple.FinderInfo "$hex" "$XCODE_APP"; then
        log "CRITICO: rollback FinderInfo falhou; valor preservado em $saved"
    fi
    return 1
}

# Chamado depois da troca de versao. NAO altera apps que ja validam.
# Corrige um tipo de problema por tentativa e, sempre que possivel, revalida.
ensure_original_integrity() {
    local ver detail_log
    ver=$(app_version "$XCODE_APP") || return 1
    if verify_signature; then
        INTEGRITY_OUTCOME="valid"
        log "ASSINATURA_OK: Xcode $ver sem necessidade de reparo"
        return 0
    fi
    log "Assinatura do Xcode $ver invalida; realizando somente recuperacoes conhecidas"
    if [ -f "$XCODE_APP/Contents/Info.plist.bak" ]; then
        if repair_legacy_plist_backup "$ver"; then
            INTEGRITY_OUTCOME="repaired_legacy_backup"
            return 0
        fi
    fi
    # Confere a mensagem de erro ANTES de remover qualquer atributo.
    detail_log=$(/usr/bin/mktemp "$STATE_DIR/xcode_codesign.XXXXXX") || return 1
    /usr/bin/codesign --verify --strict --verbose=4 "$XCODE_APP" > "$detail_log" 2>&1 || true
    /usr/bin/tail -n 12 "$detail_log" >> "$SCRIPT_LOG"
    if /usr/bin/grep -qi 'resource fork, Finder information, or similar detritus not allowed' "$detail_log" \
        && /usr/bin/xattr -p com.apple.FinderInfo "$XCODE_APP" >/dev/null 2>&1; then
        /bin/rm -f "$detail_log"
        if repair_finderinfo_root "$ver"; then
            INTEGRITY_OUTCOME="repaired_finderinfo"
            return 0
        fi
    else
        /bin/rm -f "$detail_log"
    fi
    INTEGRITY_OUTCOME="invalid"
    log "ASSINATURA_INVALIDA: Xcode $ver. Nao sera tentada inicializacao automatica."
    return 1
}

cleanup() {
    # Se a politica for interrompida com o aviso de Xcode aberto, fecha
    # somente a janela criada pelo gerenciador (nunca o Xcode do usuario).
    if [ -n "$WARNING_FILE" ] && [ -f "$WARNING_FILE" ]; then
        /bin/echo "quit:" >> "$WARNING_FILE" || true
    fi
    if [ -n "$WARNING_PID" ] && /bin/kill -0 "$WARNING_PID" 2>/dev/null; then
        /bin/kill -TERM "$WARNING_PID" 2>/dev/null || true
        wait "$WARNING_PID" 2>/dev/null || true
    fi
    [ -n "$WARNING_FILE" ] && /bin/rm -f "$WARNING_FILE"
    WARNING_FILE=""
    WARNING_PID=""
    # Restauracao antes de remover lock ou retornar ao Jamf.
    if [ "$FIX_SWAP_ACTIVE" -eq 1 ] || [ -f "$BACKUP_PLIST" ]; then
        restore_pending_plist || log "CRITICO: restauracao pendente; verificar $BACKUP_PLIST"
    fi
    audit "SESSAO_FIM mode=$SELECTION_MODE fix=$FIX_OUTCOME integridade=$INTEGRITY_OUTCOME"
    progress_stop
    if [ "$LOCK_OWNED" -eq 1 ]; then
        /bin/rm -rf "$LOCK_DIR"
    fi
    return 0
}

on_signal() {
    log "Sinal de interrupcao recebido. Iniciando limpeza."
    exit 130
}

# Verifica se o Xcode escolhido ja esta rodando; nunca encerra sessoes existentes.
# O padrao da ps identifica o binario real, nao janelas ou processos auxiliares.
xcode_pids() {
    /usr/bin/pgrep -U "$CONSOLE_UID" -f \
        '^/Applications/Xcode[.]app/Contents/MacOS/Xcode([[:space:]]|$)' 2>/dev/null || true
}

other_xcode_running() {
    /usr/bin/pgrep -U "$CONSOLE_UID" -f \
        '^/Applications/Xcode[^[:space:]]*[.]app/Contents/MacOS/Xcode([[:space:]]|$)' \
        >/dev/null 2>&1
}

# Se o usuario ja tiver o Xcode aberto, nunca o fecha nem renomeia o app.
# O launcher /usr/local/bin/dialog inicia o aplicativo na sessao grafica
# do usuario: o arquivo de comandos deve ser acessivel a esse usuario.
# Retornos: 0=voltar ao seletor; 2=cancelar a politica sem erro.
# A falha na interface tambem retorna 2 (sem apresentar a janela de "Erro").
warning_fallback_dialog() {
    local diag_file="$1" status=0
    log "AVISO_FALLBACK: janela monitorada indisponivel; tentando aviso simples do SwiftDialog."
    "$DIALOG" --title "Gerenciador Xcode — Xcode em uso" \
        --message "Um Xcode está aberto no Mac.\n\n**Salve seu trabalho e feche o Xcode** antes de alterar a versão.\n\nDepois de fechar, clique em **Voltar ao seletor**. Você também pode cancelar sem fazer alterações." \
        --icon "$ICON_URL" --overlayicon caution \
        --button1text "Voltar ao seletor" --button2text "Cancelar" \
        --width 650 --height 350 --moveable --ontop \
        > "$diag_file" 2>&1 || status=$?
    case "$status" in
        0)
            log "AVISO_FALLBACK: usuario retornou ao seletor (status 0)."
            return 0
            ;;
        2|10)
            log "AVISO_FALLBACK: usuario cancelou (status $status); politica sem erro."
            return 2
            ;;
        *)
            log "AVISO_FALLBACK_INDISPONIVEL: SwiftDialog retornou status $status; politica sera encerrada normalmente."
            if [ -s "$diag_file" ]; then
                /usr/bin/tail -n 12 "$diag_file" | while IFS= read -r line; do log "AVISO_SWIFTDIALOG: ${line:0:250}"; done
            fi
            return 2
            ;;
    esac
}

wait_for_xcode_close() {
    local warning_file warning_pid status=0 diag_file
    if ! other_xcode_running; then
        log "XCODE_FECHADO: usuario fechou antes do aviso; retornando ao seletor."
        return 0
    fi

    # Log do SwiftDialog fica disponivel para diagnosticar falha no launcher.
    diag_file="$STATE_DIR/dialog_aviso_ultimo.log"
    if ! /usr/bin/touch "$diag_file"; then
        log "AVISO: impossivel preparar o log do aviso; encerrando politica sem erro."
        return 2
    fi
    /bin/chmod 640 "$diag_file" 2>/dev/null || true
    /usr/sbin/chown root:admin "$diag_file" 2>/dev/null || true
    grant_read_access "$diag_file" file || true

    warning_file=$(/usr/bin/mktemp /var/tmp/bra_xcode_inuse.XXXXXX) || {
        log "AVISO: mktemp falhou; usando aviso simples."
        warning_fallback_dialog "$diag_file"
        return $?
    }

    # Fundamental: mktemp cria o arquivo 0600/root. Como dialogcli executa
    # Dialog no contexto do usuario grafico, ajustar proprietario para ele.
    if ! /usr/sbin/chown "$CONSOLE_USER" "$warning_file" || \
       ! /bin/chmod 600 "$warning_file" || \
       ! /usr/bin/sudo -u "$CONSOLE_USER" /bin/test -r "$warning_file" || \
       ! /usr/bin/sudo -u "$CONSOLE_USER" /bin/test -w "$warning_file"; then
        log "AVISO_ACESSO_COMMANDFILE: $CONSOLE_USER nao consegue ler/gravar o commandfile."
        /bin/rm -f "$warning_file"
        warning_fallback_dialog "$diag_file"
        return $?
    fi

    WARNING_FILE="$warning_file"
    log "XCODE_EM_USO: aviso monitorado iniciado; commandfile acessivel ao usuario grafico."
    "$DIALOG" --title "Gerenciador Xcode — Xcode em uso" \
        --message "Um Xcode está aberto no Mac.\n\n**Salve seu trabalho e encerre o Xcode** para alterar a versão.\n\nAo fechar o aplicativo, esta janela se encerrará automaticamente e você voltará à seleção de versões.\n\nVocê também pode voltar ao seletor agora ou cancelar sem alterar nada." \
        --icon "$ICON_URL" --overlayicon caution \
        --button1text "Voltar ao seletor" --button2text "Cancelar" \
        --width 650 --height 370 --moveable --ontop \
        --commandfile "$warning_file" > "$diag_file" 2>&1 &
    warning_pid=$!
    WARNING_PID="$warning_pid"

    # Monitora o aplicativo real, nao o tempo de uma janela.
    while other_xcode_running; do
        if ! /bin/kill -0 "$warning_pid" 2>/dev/null; then
            wait "$warning_pid" || status=$?
            WARNING_PID=""
            WARNING_FILE=""
            /bin/rm -f "$warning_file"
            case "$status" in
                0)
                    log "AVISO: usuario retornou ao seletor com Xcode ainda aberto."
                    return 0
                    ;;
                2|10)
                    log "AVISO: usuario cancelou, sem erro na politica."
                    return 2
                    ;;
                *)
                    log "AVISO_SWIFTDIALOG: dialog monitorado encerrou com status $status."
                    if [ -s "$diag_file" ]; then
                        /usr/bin/tail -n 12 "$diag_file" | while IFS= read -r line; do log "AVISO_SWIFTDIALOG: ${line:0:250}"; done
                    fi
                    warning_fallback_dialog "$diag_file"
                    return $?
                    ;;
            esac
        fi
        /bin/sleep 2
    done

    # Caso o Xcode feche entre o polling e a abertura, nao deixa janela orfa.
    log "XCODE_FECHADO: encerrando aviso e reabrindo seletor nesta mesma politica."
    if /bin/kill -0 "$warning_pid" 2>/dev/null; then
        /bin/echo "quit:" >> "$warning_file"  # Exit 5 = fechamento por commandfile
        wait "$warning_pid" 2>/dev/null || true
    else
        wait "$warning_pid" 2>/dev/null || true
    fi
    WARNING_PID=""
    WARNING_FILE=""
    /bin/rm -f "$warning_file"
    return 0
}

# Tenta a mesma abertura solicitada pelo fix original, mas ocultando a UI.
# Diferente do 3.1: passa o CAMINHO do app, sem --env nem -a, evitando
# sinalizar um app "diferente" no LaunchServices. Sem fallback visivel.
# IMPORTANTE: o macOS pode mostrar janela de seguranca e/ou rejeitar assinatura.
launch_hidden_once() {
    local pid="" round=0
    if other_xcode_running; then
        log "Fix cancelado: ha Xcode aberto, protegendo projetos do usuario"
        return 1
    fi
    log "Tentativa de abertura oculta do Xcode com plist temporario (open -g -j)"
    audit "OPEN_OCULTO_INICIO user=$CONSOLE_USER uid=$CONSOLE_UID app=$XCODE_APP"
    local open_output="" open_rc=0
    open_output=$(/bin/launchctl asuser "$CONSOLE_UID" /usr/bin/sudo -u "$CONSOLE_USER" \
        /usr/bin/open -g -j "$XCODE_APP" 2>&1)
    open_rc=$?
    [ -z "$open_output" ] || /usr/bin/printf '%s\n' "$open_output" >> "$SCRIPT_LOG"
    audit "OPEN_OCULTO_RC=$open_rc mensagem=$(/usr/bin/printf '%s' "$open_output" | /usr/bin/tr '\n' ' ' | /usr/bin/cut -c 1-750)"
    if [ "$open_rc" -ne 0 ]; then
        if expected_launchservices_block "$open_output"; then
            FIX_OPEN_BLOCKED_EXPECTED=1
            audit "ABERTURA_TEMPORARIA_BLOQUEIO_ESPERADO rc=$open_rc"
            log "ABERTURA_BLOQUEADA_ESPERADA: open -g -j recusado pelo macOS durante o plist temporario"
        else
            log "ABERTURA_OCULTA_NAO_CONFIRMADA: open -g -j falhou por motivo nao classificado"
        fi
        return 1
    fi
    while [ "$round" -lt 20 ]; do
        pid=$(xcode_pids | /usr/bin/head -n 1)
        [ -n "$pid" ] && break
        /bin/sleep 1
        round=$((round + 1))
    done
    if [ -z "$pid" ]; then
        log "ABERTURA_NAO_CONFIRMADA: nao apareceu processo Xcode em 20s"
        return 1
    fi
    log "Instancia de teste identificada, PID $pid"
    /bin/sleep 3
    if ! /bin/kill -TERM "$pid" 2>/dev/null; then
        log "ENCERRAMENTO_NAO_CONFIRMADO: nao foi possivel solicitar TERM ao PID $pid"
        return 1
    fi
    round=0
    while [ "$round" -lt 20 ]; do
        if ! /bin/kill -0 "$pid" 2>/dev/null; then
            log "Instancia de teste encerrada: PID $pid"
            return 0
        fi
        /bin/sleep 1
        round=$((round + 1))
    done
    log "ENCERRAMENTO_NAO_CONFIRMADO: PID $pid ainda ativo; nao executamos kill -9"
    return 1
}

# Um erro conhecido de abertura com o plist original/temporario nao e um
# erro de integridade. Nao mascarar falhas diferentes (permissao, launchctl etc).
expected_launchservices_block() {
    case "$1" in
        *-10664*|*'Code=163'*|*'kLSIncompatibleApplicationVersionErr'*|*'invalid bundle signature'*) return 0 ;;
    esac
    return 1
}

# TESTE APENAS para uma instalacao NOVA que requer fix.
# Executa DEPOIS de validar a assinatura original e ANTES de copiar qualquer
# Info.plist. Se a abertura inicial falhar por bloqueio conhecido, CONTINUA.
# Se iniciar um Xcode, so encerra o unico processo identificado no caminho
# ativo (nunca usa killall, -9 ou fecha instancias que ja estavam abertas).
# Retorna 0: pre-teste concluido ou bloqueado pelo macOS; 1: inseguro prosseguir.
preopen_original_once() {
    local output="" rc=0 pid="" pids="" ps_cmd="" round=0 max_rounds=3
    PREOPEN_ORIGINAL_OUTCOME="not_attempted"
    if [ "$SELECTION_MODE" != "install" ] || [ "$PREOPEN_ORIGINAL_ON_INSTALL" != 1 ]; then
        audit "PRE_ABERTURA_ORIGINAL=dispensada modo=${SELECTION_MODE:-unknown}"
        return 0
    fi
    if other_xcode_running; then
        PREOPEN_ORIGINAL_OUTCOME="xcode_already_running"
        audit "PRE_ABERTURA_ORIGINAL_NAO_EXECUTADA motivo=xcode_ja_aberto"
        log "PRE_ABERTURA_ORIGINAL: Xcode ja esta aberto; nao manipular plist"
        return 1
    fi
    audit "PRE_ABERTURA_ORIGINAL_INICIO app=$XCODE_APP version=$(app_version "$XCODE_APP" 2>/dev/null || true) plist_sha=$(sha256 "$XCODE_APP/Contents/Info.plist" 2>/dev/null || true)"
    log "PRE_ABERTURA_ORIGINAL: tentativa oculta antes do backup e plist temporario"
    output=$(/bin/launchctl asuser "$CONSOLE_UID" /usr/bin/sudo -u "$CONSOLE_USER" \
        /usr/bin/open -g -j "$XCODE_APP" 2>&1)
    rc=$?
    [ -z "$output" ] || /usr/bin/printf '%s\n' "$output" >> "$SCRIPT_LOG"
    audit "PRE_ABERTURA_ORIGINAL_OPEN_RC=$rc mensagem=$(/usr/bin/printf '%s' "$output" | /usr/bin/tr '\n' ' ' | /usr/bin/cut -c 1-750)"
    if [ "$rc" -ne 0 ]; then
        if expected_launchservices_block "$output"; then
            PREOPEN_ORIGINAL_OUTCOME="blocked_expected"
            audit "PRE_ABERTURA_ORIGINAL_BLOQUEIO_ESPERADO rc=$rc"
            log "PRE_ABERTURA_ORIGINAL_BLOQUEIO_ESPERADO: LaunchServices recusou abertura; continuando fix normalmente"
        else
            PREOPEN_ORIGINAL_OUTCOME="open_not_confirmed"
            audit "PRE_ABERTURA_ORIGINAL_NAO_CONFIRMADA rc=$rc"
            log "PRE_ABERTURA_ORIGINAL_NAO_CONFIRMADA: retorno nao reconhecido; registrando e conferindo se criou processo"
        fi
    else
        PREOPEN_ORIGINAL_OUTCOME="open_command_ok"
        max_rounds=12
    fi

    # Uma abertura pode iniciar o processo mesmo que a chamada nao confirme;
    # detectar e fechar antes de qualquer alteracao ao bundle.
    while [ "$round" -lt "$max_rounds" ]; do
        pids=$(xcode_pids)
        [ -n "$pids" ] && break
        /bin/sleep 1
        round=$((round + 1))
    done
    if [ -z "$pids" ]; then
        # Refaz a verificacao para evitar iniciar a troca com um Xcode aberto.
        if other_xcode_running; then
            PREOPEN_ORIGINAL_OUTCOME="late_process_detected"
            audit "PRE_ABERTURA_ORIGINAL_INSEGURO processo_apareceu_tardiamente"
            return 1
        fi
        audit "PRE_ABERTURA_ORIGINAL_SEM_PROCESSO estado=$PREOPEN_ORIGINAL_OUTCOME"
        return 0
    fi
    # Se um usuario iniciou outra instancia simultaneamente, nao adivinhar
    # qual processo pertence ao teste.
    case "$pids" in
        *$'\n'*)
            PREOPEN_ORIGINAL_OUTCOME="multiple_processes"
            audit "PRE_ABERTURA_ORIGINAL_INSEGURO multiplos_processos_detectados"
            return 1 ;;
    esac
    pid="$pids"
    case "$pid" in
        ''|*[!0-9]*)
            PREOPEN_ORIGINAL_OUTCOME="invalid_pid"
            audit "PRE_ABERTURA_ORIGINAL_INSEGURO pid_invalido"
            return 1 ;;
    esac
    ps_cmd=$(/bin/ps -p "$pid" -o command= 2>/dev/null || true)
    case "$ps_cmd" in
        "$XCODE_APP/Contents/MacOS/Xcode"|"$XCODE_APP/Contents/MacOS/Xcode "*) ;;
        *)
            audit "PRE_ABERTURA_ORIGINAL_INSEGURO pid=$pid comando_nao_corresponde"
            return 1 ;;
    esac
    audit "PRE_ABERTURA_ORIGINAL_PROCESSO_INICIADO pid=$pid"
    # Se conseguiu iniciar, permite alguns segundos para a inicializacao grafica.
    /bin/sleep 5
    # Nao enviar TERM caso PID tenha sido reciclado ou comando tenha mudado.
    ps_cmd=$(/bin/ps -p "$pid" -o command= 2>/dev/null || true)
    case "$ps_cmd" in
        "")
            PREOPEN_ORIGINAL_OUTCOME="opened_and_exited"
            audit "PRE_ABERTURA_ORIGINAL_ENCERROU_SOZINHA pid=$pid"
            return 0 ;;
        "$XCODE_APP/Contents/MacOS/Xcode"|"$XCODE_APP/Contents/MacOS/Xcode "*) ;;
        *)
            audit "PRE_ABERTURA_ORIGINAL_INSEGURO pid=$pid comando_alterado"
            return 1 ;;
    esac
    if ! /bin/kill -TERM "$pid" 2>/dev/null; then
        audit "PRE_ABERTURA_ORIGINAL_TERM_NAO_CONFIRMADO pid=$pid"
        # Se ja encerrou naturalmente, e seguro continuar.
        if /bin/kill -0 "$pid" 2>/dev/null; then
            PREOPEN_ORIGINAL_OUTCOME="process_remains_open"
            return 1
        fi
    fi
    round=0
    while [ "$round" -lt 20 ]; do
        if ! /bin/kill -0 "$pid" 2>/dev/null; then
            PREOPEN_ORIGINAL_OUTCOME="opened_and_closed"
            audit "PRE_ABERTURA_ORIGINAL_ENCERRADA pid=$pid"
            log "PRE_ABERTURA_ORIGINAL: instancia de teste encerrada, seguindo fix"
            return 0
        fi
        /bin/sleep 1
        round=$((round + 1))
    done
    PREOPEN_ORIGINAL_OUTCOME="process_remains_open"
    audit "PRE_ABERTURA_ORIGINAL_NAO_ENCERRADA pid=$pid; sem kill -9, nao trocar plist"
    log "PRE_ABERTURA_ORIGINAL: instancia permaneceu aberta; preservando integridade e nao alterando plist"
    return 1
}

# Fonte original do 3.1: referencia instalada da mesma geracao do macOS,
# ou plist original previamente homologado e disponibilizado em SantanderFiles.
find_reference_plist() {
    local target_major="$1" candidate v major key best_key="" best_plist=""
    shopt -s nullglob
    for candidate in "$BASE_DIR"/Xcode*.app; do
        [ "$candidate" = "$XCODE_APP" ] && continue
        app_valid "$candidate" || continue
        v=$(app_version "$candidate") || continue
        major=$(version_major "$v") || continue
        [ "$major" -eq "$target_major" ] || continue
        key=$(version_key "$v") || continue
        if [ -z "$best_key" ] || [[ "$key" > "$best_key" ]]; then
            best_key="$key"
            best_plist="$candidate/Contents/Info.plist"
        fi
    done
    shopt -u nullglob
    if [ -n "$best_plist" ]; then
        /bin/echo "$best_plist"
        return 0
    fi
    if [ "$target_major" -eq 27 ]; then
        candidate="$FIX_BASE/Plist_Xcode_27/Info.plist"
    elif [ "$target_major" -eq 26 ]; then
        candidate="$FIX_BASE/Plist_Xcode_26.2/Info.plist"
    else
        return 1
    fi
    [ -f "$candidate" ] || return 1
    /bin/echo "$candidate"
}

# Retorno: 0 = requer fix; 1 = nao requer.
needs_compat_fix() {
    local osversion="$1" xcodeversion="$2" osmajor osminor xmajor
    osmajor=$(version_major "$osversion") || return 1
    xmajor=$(version_major "$xcodeversion") || return 1
    if [ "$osmajor" -eq 27 ] && [ "$xmajor" -lt 27 ]; then
        return 0
    fi
    if [ "$osmajor" -eq 26 ] && [ "$xmajor" -lt 26 ]; then
        osminor=$(/bin/echo "$osversion" | /usr/bin/awk -F. '{print $2+0}')
        # 16.4 foi homologado pela Apple ate macOS 26.1.x.
        if [ "$xcodeversion" = "16.4" ] && [ "$osminor" -le 1 ]; then
            return 1
        fi
        return 0
    fi
    return 1
}

# Fix reversivel do 3.1 integrado a recuperacao de integridade da 3.2.
# A substituicao do plist TEMPORARIAMENTE invalida a assinatura.
# Retornos: 0 = fix dispensado ou abertura/encerramento confirmado;
#           1 = precondicao/abertura nao confirmada por outro motivo;
#           2 = falha CRITICA de restauracao/hash/assinatura pos-fix;
#           3 = bloqueio esperado na abertura temporaria, restauracao SHA OK.
compat_fix() {
    local osv ver osmajor src actual_major expected_hash status=0
    FIX_OPEN_BLOCKED_EXPECTED=0
    osv=$(/usr/bin/sw_vers -productVersion) || return 1
    ver=$(app_version "$XCODE_APP") || return 1

    if ! ensure_original_integrity; then
        log "FIX_NAO_CONFIRMADO: assinatura original nao recuperada (Xcode $ver)"
        return 1
    fi
    if ! needs_compat_fix "$osv" "$ver"; then
        log "Fix dispensado: macOS $osv, Xcode $ver; assinatura original valida"
        return 0
    fi
    if other_xcode_running; then
        log "FIX_NAO_CONFIRMADO: Xcode ja aberto; nenhum processo do usuario sera encerrado"
        return 1
    fi
    osmajor=$(version_major "$osv") || return 1
    src=$(find_reference_plist "$osmajor") || {
        log "FIX_NAO_CONFIRMADO: nao ha plist de referencia Xcode $osmajor instalado ou em SantanderFiles"
        return 1
    }
    if ! /usr/bin/plutil -lint "$src" >/dev/null 2>&1; then
        log "FIX_NAO_CONFIRMADO: plist de referencia invalido: $src"
        return 1
    fi
    if [ "$(get_plist_value "$src" CFBundleIdentifier)" != "com.apple.dt.Xcode" ]; then
        log "FIX_NAO_CONFIRMADO: BundleID da referencia nao corresponde a Xcode"
        return 1
    fi
    actual_major=$(version_major "$(get_plist_value "$src" CFBundleShortVersionString)") || return 1
    if [ "$actual_major" -ne "$osmajor" ]; then
        log "FIX_NAO_CONFIRMADO: major de referencia $actual_major diverge da major macOS $osmajor"
        return 1
    fi
    if [ -e "$BACKUP_PLIST" ] || [ -e "$BACKUP_INODE" ]; then
        log "FIX_NAO_CONFIRMADO: ja existe estado pendente de outra tentativa"
        return 1
    fi

    # Experimento especifico: PRIMEIRA abertura com plist ORIGINAL.
    # A assinatura ja foi verificada por ensure_original_integrity().
    # A tentativa anterior a troca nunca e requisito de sucesso: -10664/163
    # sao esperados, desde que nenhum processo tenha ficado aberto.
    if ! preopen_original_once; then
        log "FIX_PRE_ABERTURA_ABORTADA_POR_SEGURANCA: Xcode em execucao; nenhum plist alterado"
        audit "PRE_ABERTURA_ORIGINAL_RESULTADO=unsafe; fix_plist_nao_iniciado"
        return 1
    fi
    audit "PRE_ABERTURA_ORIGINAL_RESULTADO=$PREOPEN_ORIGINAL_OUTCOME"
    if other_xcode_running; then
        log "FIX_PRE_ABERTURA_ABORTADA_POR_SEGURANCA: Xcode ainda ativo apos teste; nenhum plist alterado"
        audit "PRE_ABERTURA_ORIGINAL_RESULTADO=unsafe_app_still_running"
        return 1
    fi

    # Backups externos, protegidos contra queda/sinal; o original nao fica .bak no .app.
    if ! app_inode "$XCODE_APP" > "$BACKUP_INODE"; then
        log "FIX_NAO_CONFIRMADO: nao foi possivel guardar inode do app"
        return 1
    fi
    if ! /bin/cp -p "$XCODE_APP/Contents/Info.plist" "$BACKUP_PLIST.tmp.$$"; then
        /bin/rm -f "$BACKUP_INODE" "$BACKUP_PLIST.tmp.$$"
        log "FIX_NAO_CONFIRMADO: falha ao copiar plist original"
        return 1
    fi
    if ! /bin/mv "$BACKUP_PLIST.tmp.$$" "$BACKUP_PLIST"; then
        /bin/rm -f "$BACKUP_INODE" "$BACKUP_PLIST.tmp.$$"
        log "FIX_NAO_CONFIRMADO: nao foi possivel concluir backup externo"
        return 1
    fi
    expected_hash=$(sha256 "$BACKUP_PLIST") || {
        log "FIX_NAO_CONFIRMADO: falha ao calcular hash do backup externo"
        restore_pending_plist || true
        return 1
    }
    log "FIX_TEMPORARIO: macOS $osv; Xcode $ver; referencia=$src; backup_sha=$expected_hash"
    audit "FIX_BACKUP_OK backup_sha=$expected_hash backup_inode=$(/bin/cat "$BACKUP_INODE" 2>/dev/null || true)"
    audit "FIX_REFERENCIA path=$src version=$(get_plist_value "$src" CFBundleShortVersionString) build=$(get_plist_value "$src" CFBundleVersion) sha=$(sha256 "$src" 2>/dev/null || true)"
    FIX_SWAP_ACTIVE=1

    # Copia temporaria: possivel rejeicao pelo AMFI/LaunchServices durante o swap.
    if ! /bin/cp -p "$src" "$XCODE_APP/Contents/Info.plist"; then
        audit "FIX_TEMP_COPIA=falha"
        log "FIX_NAO_CONFIRMADO: erro ao aplicar plist temporario"
        status=1
    else
        # cmp confirma o conteudo exato com impacto minimo de tempo.
        if /usr/bin/cmp -s "$src" "$XCODE_APP/Contents/Info.plist"; then
            audit "FIX_TEMP_COPIA=identica_ao_plist_referencia"
        else
            audit "FIX_TEMP_COPIA=divergente"
        fi
        if ! launch_hidden_once; then
            if [ "$FIX_OPEN_BLOCKED_EXPECTED" -eq 1 ]; then
                log "FIX_ABERTURA_TEMPORARIA_BLOQUEIO_ESPERADO: continuando restauracao original"
            else
                log "FIX_NAO_CONFIRMADO: abertura oculta nao confirmada (motivo diferente dos bloqueios conhecidos)"
            fi
            status=1
        fi
        # EXPERIMENTO UNICO: verificar se a restauracao imediata apos o retorno
        # de open explica o resultado diferente em uma instalacao nova.
        # Aplicar espera SOMENTE ao modo install; versoes ja instaladas ficam
        # com a sequencia exata da 3.7. Nenhuma chamada extra a open/codesign.
        if [ "$SELECTION_MODE" = "install" ]; then
            audit "FIX_ESPERA_POS_OPEN_INICIO segundos=5 status_abertura=$status bloqueio_esperado=$FIX_OPEN_BLOCKED_EXPECTED"
            log "FIX_ESPERA_POS_OPEN_INICIO: aguardando 5 segundos antes de restaurar Info.plist temporario"
            /bin/sleep 5
            # Observacao somente leitura: detectar inicializacao tardia.
            local late_xcode_pids=""
            late_xcode_pids=$(xcode_pids | /usr/bin/tr '\n' ',' | /usr/bin/sed 's/,$//')
            if [ -n "$late_xcode_pids" ]; then
                audit "FIX_ESPERA_POS_OPEN_FIM processo_tardio=sim pids=$late_xcode_pids"
                log "FIX_ESPERA_POS_OPEN_FIM: processo Xcode detectado apos 5 segundos; restauracao de integridade sera executada"
            else
                audit "FIX_ESPERA_POS_OPEN_FIM processo_tardio=nao"
                log "FIX_ESPERA_POS_OPEN_FIM: nenhum processo Xcode; restaurando Info.plist original"
            fi
        fi
    fi

    # SEMPRE restaurar o plist exato, inclusive se a abertura falhar.
    # restore_pending_plist ja calcula SHA-256 do backup E do arquivo restaurado,
    # compara ambos e so apaga o estado pendente apos validar a igualdade.
    if ! restore_pending_plist; then
        log "CRITICO: restauracao pendente - nao trocar o Xcode ate recuperar $BACKUP_PLIST"
        post_restore_signature_diagnostic || true
        return 2
    fi
    # Verificacao independente de SHA-256, barata (Info.plist ~dezenas de KB).
    # Em caso de divergencia, impedir sucesso e executar diagnostico profundo.
    local restored_hash
    restored_hash=$(sha256 "$XCODE_APP/Contents/Info.plist") || restored_hash=""
    audit "FIX_RESTAURACAO original_sha=$expected_hash restaurado_sha=${restored_hash:-unavailable} status=$status"
    if [ -z "$restored_hash" ] || [ "$restored_hash" != "$expected_hash" ]; then
        log "CRITICO: SHA-256 divergente apos restaurar plist original; esperado=$expected_hash obtido=$restored_hash"
        post_restore_signature_diagnostic || true
        return 2
    fi
    # Otimizacao 3.6: a assinatura original foi verificada antes do swap.
    # Apos a restauracao, SHA-256 valido dispensa o segundo codesign (~25-30s).
    # Somente a auditoria explicita valida novamente a assinatura.
    if [ "$POST_RESTORE_CODESIGN_MODE" = "always" ]; then
        if ! verify_signature; then
            log "CRITICO: assinatura invalida APOS restauracao (modo auditoria)"
            post_restore_signature_diagnostic || true
            return 2
        fi
        log "POS_RESTAURACAO: SHA-256 OK; codesign pos-fix validado (modo always)"
    else
        log "POS_RESTAURACAO: SHA-256 OK; segunda verificacao codesign dispensada (modo on_failure)"
    fi
    if [ "$status" -ne 0 ]; then
        if [ "$FIX_OPEN_BLOCKED_EXPECTED" -eq 1 ]; then
            log "FIX_FLUXO_CONCLUIDO_BLOQUEIO_ESPERADO: plist original restaurado e SHA-256 OK; Finder ainda nao validado"
            audit "FIX_BLOQUEIO_ESPERADO_NAO_PENDENCIA=sim; restauracao=ok"
            return 3
        fi
        log "FIX_NAO_CONFIRMADO: plist original restaurado e SHA-256 confirmado; Finder nao validado"
        return 1
    fi
    log "FIX_FLUXO_OK: abriu/encerrou oculto e restaurou plist original; Finder ainda nao garantido"
    return 0
}

# Descobre instalacoes pelo numero real em Info.plist, nao apenas pelo nome.
find_installed_version() {
    local version="$1" candidate v
    if app_valid "$XCODE_APP"; then
        v=$(app_version "$XCODE_APP") || v=""
        [ "$v" = "$version" ] && { /bin/echo "$XCODE_APP"; return 0; }
    fi
    shopt -s nullglob
    for candidate in "$BASE_DIR"/Xcode*.app; do
        [ "$candidate" = "$XCODE_APP" ] && continue
        app_valid "$candidate" || continue
        v=$(app_version "$candidate") || continue
        if [ "$v" = "$version" ]; then
            /bin/echo "$candidate"
            shopt -u nullglob
            return 0
        fi
    done
    shopt -u nullglob
    return 1
}

# Move o Xcode atual para nome versionado, sem substituir outro aplicativo.
# Retorna 0 se nao existe ou ja coincide com versao selecionada.
move_current_aside() {
    local selected_ver="$1" old_ver destination
    [ -d "$XCODE_APP" ] || return 0
    old_ver=$(app_version "$XCODE_APP") || { log "Xcode.app sem versao valida"; return 1; }
    [ "$old_ver" = "$selected_ver" ] && return 0
    destination="$BASE_DIR/Xcode_${old_ver}.app"
    if [ -e "$destination" ]; then
        log "Conflito: $destination ja existe. Nenhum aplicativo foi sobrescrito."
        return 1
    fi
    /bin/mv "$XCODE_APP" "$destination" || return 1
    log "Renomeado $XCODE_APP -> $destination"
    return 0
}

select_default_xcode() {
    local actual path
    app_valid "$XCODE_APP" || { log "Xcode.app nao encontrado/valido"; return 1; }
    actual=$(app_version "$XCODE_APP") || return 1
    path="$XCODE_APP/Contents/Developer"
    /usr/bin/xcode-select -s "$path" >> "$SCRIPT_LOG" 2>&1 || return 1
    export DEVELOPER_DIR="$path"
    log "Xcode $actual definido como padrao: $path"
    return 0
}

perform_selection() {
    local version="$1" trigger="$2" installed="" previous="" current="" selected_app="" jamf_rc=0 fix_rc=0

    if other_xcode_running; then
        log "XCODE_EM_USO: selecao adiada; exibiremos aviso e retornaremos ao seletor."
        return 4
    fi
    installed=$(find_installed_version "$version") || installed=""
    audit "SELECAO_INICIO version=$version trigger=$trigger installed=${installed:-NAO}"
    audit_snapshot "ANTES_DA_SELECAO"
    if [ -n "$installed" ]; then
        SELECTION_MODE="installed"
        log "Xcode $version encontrado em $installed"
        if [ "$installed" != "$XCODE_APP" ]; then
            if [ -d "$XCODE_APP" ]; then
                current=$(app_version "$XCODE_APP") || return 1
                previous="$BASE_DIR/Xcode_${current}.app"
                if [ "$current" != "$version" ]; then
                    show_rename_dialog "$current" "installed" || return 3
                fi
            fi
            if other_xcode_running; then
                log "XCODE_EM_USO: aplicativo aberto durante a confirmacao; nenhuma renomeacao executada."
                return 4
            fi
            move_current_aside "$version" || return 1
            if ! /bin/mv "$installed" "$XCODE_APP"; then
                log "Falha ao ativar $installed"
                if [ -n "$previous" ] && [ ! -e "$XCODE_APP" ] && [ -d "$previous" ]; then
                    /bin/mv "$previous" "$XCODE_APP" || true
                fi
                return 1
            fi
        fi
    else
        SELECTION_MODE="install"
        if [ "$trigger" = "INSTALLED_ONLY" ]; then
            log "Xcode $version nao esta mais instalado; nao existe trigger Jamf para essa entrada"
            return 1
        fi
        log "Xcode $version nao instalado; iniciando trigger Jamf: $trigger"
        if [ -d "$XCODE_APP" ]; then
            current=$(app_version "$XCODE_APP") || return 1
            previous="$BASE_DIR/Xcode_${current}.app"
            if [ "$current" != "$version" ]; then
                show_rename_dialog "$current" "install" || return 3
            fi
        fi
        if other_xcode_running; then
            log "XCODE_EM_USO: aplicativo aberto durante a confirmacao da instalacao; nenhuma renomeacao executada."
            return 4
        fi
        move_current_aside "$version" || return 1
        audit_snapshot "APOS_RENOMEAR_ANTES_JAMF"
        progress_start || log "AVISO_PROGRESSO: janela indisponivel; instalacao Jamf prosseguira sem barra visual"
        progress_cmd "progresstext: Instalando Xcode $version via Jamf..."
        run_jamf_with_progress "$trigger"
        jamf_rc=$?
        audit "JAMF_TRIGGER_FIM trigger=$trigger rc=$jamf_rc"
        audit_snapshot "POS_JAMF_ANTES_VERIFICACAO"
        progress_cmd "progresstext: Verificando instalacao..."
        if [ "$jamf_rc" -ne 0 ]; then
            log "Trigger $trigger retornou codigo $jamf_rc"
            if [ ! -e "$XCODE_APP" ] && [ -n "$previous" ] && [ -d "$previous" ]; then
                /bin/mv "$previous" "$XCODE_APP" || true
            fi
            return 1
        fi
        selected_app=$(find_installed_version "$version") || selected_app=""
        audit "POS_JAMF_LOCALIZACAO selected_app=${selected_app:-NAO_ENCONTRADO} version=$version"
        if [ -z "$selected_app" ]; then
            log "Trigger $trigger concluiu, mas Xcode $version nao foi localizado"
            if [ ! -e "$XCODE_APP" ] && [ -n "$previous" ] && [ -d "$previous" ]; then
                /bin/mv "$previous" "$XCODE_APP" || true
            fi
            return 1
        fi
        if [ "$selected_app" != "$XCODE_APP" ]; then
            if [ -e "$XCODE_APP" ]; then
                log "Instalador criou outro Xcode.app; nao sobrescrever."
                return 1
            fi
            /bin/mv "$selected_app" "$XCODE_APP" || return 1
        fi
    fi

    if [ "$(app_version "$XCODE_APP")" != "$version" ]; then
        log "Versao ativa diferente da solicitada: $(app_version "$XCODE_APP")"
        return 1
    fi
    if ! select_default_xcode; then
        log "Falha ao configurar xcode-select"
        return 1
    fi
    audit_snapshot "ANTES_COMPAT_FIX"
    # Fix nao exibe alertas via SwiftDialog; restauracao ocorre antes de retornar.
    # Se falhar, nao esconder a falha no log nem alegar Finder garantido.
    progress_cmd "progresstext: Finalizando configuracoes..."
    compat_fix
    fix_rc=$?
    audit "COMPAT_FIX_RETORNO mode=$SELECTION_MODE version=$version rc=$fix_rc"
    audit_snapshot "DEPOIS_COMPAT_FIX"
    case "$fix_rc" in
        0)
            FIX_OUTCOME="ok_or_not_needed"
            ;;
        1)
            FIX_OUTCOME="not_confirmed"
            log "FIX_NAO_CONFIRMADO: Xcode $version foi selecionado; diagnostico disponivel apenas no log."
            ;;
        3)
            FIX_OUTCOME="abertura_bloqueada_esperada"
            log "FIX_BLOQUEIO_ESPERADO: Xcode $version selecionado, Info.plist original restaurado; Finder nao validado."
            ;;
        2)
            FIX_OUTCOME="critical_restore_failure"
            log "CRITICO: restauracao/integridade do Info.plist nao confirmada; interrompendo politica."
            return 1
            ;;
        *)
            FIX_OUTCOME="unexpected_fix_error"
            log "CRITICO: retorno inesperado do fix: $fix_rc"
            return 1
            ;;
    esac
    if [ "$SELECTION_MODE" = "install" ]; then
        progress_cmd "progresstext: Instalacao concluida"
        progress_cmd "progress: complete"
    fi
    return 0
}

choose_version() {
    local entries=() names=() trigs=() item selected="" output="" i current_active=""
    local active_path active_app active_version candidate foundversion major known listed_name present

    active_path=$(/usr/bin/xcode-select -p 2>/dev/null || true)
    active_app="${active_path%/Contents/Developer}"
    if [ -d "$active_app" ]; then
        active_version=$(app_version "$active_app" || true)
        [ -n "$active_version" ] && current_active="Xcode $active_version"
    fi
    for item in "${XCODE_VERSIONS[@]}"; do
        names+=("${item%:*}")
        trigs+=("${item#*:}")
    done
    # Mostrar Xcodes 27+ ja instalados, sem inventar trigger Jamf para eles.
    # So e possivel seleciona-los se realmente existirem no disco.
    shopt -s nullglob
    for candidate in "$BASE_DIR"/Xcode*.app; do
        app_valid "$candidate" || continue
        foundversion=$(app_version "$candidate") || continue
        major=$(version_major "$foundversion") || continue
        [ "$major" -ge 27 ] || continue
        listed_name="Xcode $foundversion"
        present=0
        for item in "${names[@]}"; do
            [ "$item" = "$listed_name" ] && { present=1; break; }
        done
        if [ "$present" -eq 0 ]; then
            names+=("$listed_name")
            trigs+=("INSTALLED_ONLY")
        fi
    done
    shopt -u nullglob
    entries=()
    for item in "${names[@]}"; do
        if [ "$item" = "$current_active" ]; then
            entries+=("$item (atual)")
        else
            entries+=("$item")
        fi
    done
    local values
    values=$(IFS=,; /bin/echo "${entries[*]}")
    output=$("$DIALOG" --title "Gerenciador Xcode" \
        --message "Selecione a versão do Xcode para instalar ou alternar entre versões já instaladas:" \
        --icon "$ICON_URL" --selecttitle "Versoes do Xcode",radio \
        --width 650 --height 350 --ontop --moveable \
        --selectvalues "$values" --button1text "Selecionar" \
        --button2text "Cancelar" --output 2>/dev/null) || return 2
    # Preserva o parser do script original (--output do SwiftDialog).
    selected=$(/bin/echo "$output" | /usr/bin/awk -F '"' '/SelectedOption/ {print $4; exit}')
    selected="${selected% (atual)}"
    [ -n "$selected" ] || return 2
    for ((i=0; i<${#names[@]}; i++)); do
        if [ "${names[$i]}" = "$selected" ]; then
            CHOSEN_VERSION="${selected#Xcode }"
            CHOSEN_TRIGGER="${trigs[$i]}"
            return 0
        fi
    done
    log "Opcao recebida nao consta da lista: $selected"
    return 1
}

main() {
    local result=0
    if [ "$(/usr/bin/id -u)" -ne 0 ]; then
        /bin/echo "ERRO: execute pela politica Jamf como root" >&2
        exit 1
    fi
    prepare_support_paths || {
        /bin/echo "ERRO: nao foi possivel preparar SantanderFiles e logs" >&2
        exit 1
    }

    if ! /bin/mkdir "$LOCK_DIR" 2>/dev/null; then
        # Lock de uma execucao encerrada por SIGKILL/reboot pode persistir.
        local old_pid=""
        old_pid=$(/bin/cat "$LOCK_DIR/pid" 2>/dev/null || true)
        if [[ "$old_pid" =~ ^[0-9]+$ ]] && /bin/kill -0 "$old_pid" 2>/dev/null; then
            /bin/echo "Gerenciador ja em execucao (PID $old_pid)" >&2
            exit 1
        fi
        /bin/rm -rf "$LOCK_DIR" || exit 1
        /bin/mkdir "$LOCK_DIR" || exit 1
        log "Lock antigo removido; verificando eventual restauracao pendente"
    fi
    LOCK_OWNED=1
    /bin/echo "$$" > "$LOCK_DIR/pid"
    trap cleanup EXIT
    trap on_signal INT TERM HUP
    log "======== Inicio Gerenciador Xcode 3.7 (UI V2 + Fix Temporario + SHA-256 + Progresso Jamf) ========"

    # Caso a execucao anterior tenha terminado inesperadamente, restaurar antes
    # de ler a versao ou permitir nova troca. Nao sobrescreve outro Xcode.
    if ! restore_pending_plist; then
        show_error "Existe um backup de Info.plist pendente que nao pode ser restaurado automaticamente. O gerenciador nao alterou os aplicativos. Consulte o log de suporte."
        exit 1
    fi
    if [ ! -x "$DIALOG" ]; then
        log "SwiftDialog nao encontrado em $DIALOG"
        exit 1
    fi
    CONSOLE_USER=$(/usr/bin/stat -f '%Su' /dev/console 2>/dev/null || true)
    case "$CONSOLE_USER" in
        ""|root|loginwindow|_mbsetupuser)
            log "Nenhum usuario grafico valido conectado: $CONSOLE_USER"
            exit 1
            ;;
    esac
    CONSOLE_UID=$(/usr/bin/id -u "$CONSOLE_USER") || exit 1
    prepare_console_read_access
    # Comprova acesso efetivo; avisos ficam no log, sem janela para o usuario.
    if ! /usr/bin/sudo -u "$CONSOLE_USER" /bin/test -r "$SUPPORT_LOG"; then
        log "AVISO_ACESSO: $CONSOLE_USER nao consegue ler $SUPPORT_LOG; revisar ACL herdada nos diretorios pais"
    fi
    if ! /usr/bin/sudo -u "$CONSOLE_USER" /bin/test -r "$SCRIPT_LOG"; then
        log "AVISO_ACESSO: $CONSOLE_USER nao consegue ler $SCRIPT_LOG; revisar ACL do arquivo"
    fi
    if ! /usr/bin/sudo -u "$CONSOLE_USER" /bin/test -x "$FIX_BASE"; then
        log "AVISO_ACESSO: $CONSOLE_USER nao consegue entrar em $FIX_BASE; revisar ACL dos diretorios pais"
    fi
    log "ACESSO_SUPORTE: $SCRIPT_LOG e $SUPPORT_LOG; ACL de leitura para $CONSOLE_USER"
    log "ASSINATURA_MODO: $SIGNATURE_VERIFY_MODE (fast=principal, deep=principal+componentes aninhados)"
    case "$POST_RESTORE_CODESIGN_MODE" in
        on_failure|always) ;;
        *) log "ERRO: POST_RESTORE_CODESIGN_MODE invalido: $POST_RESTORE_CODESIGN_MODE"; exit 1 ;;
    esac
    log "POS_FIX_CODESIGN_MODO: $POST_RESTORE_CODESIGN_MODE (on_failure=SHA-256; always=codesign adicional)"
    audit_init
    while :; do
        CHOSEN_VERSION=""
        CHOSEN_TRIGGER=""
        SELECTION_MODE=""
        FIX_OUTCOME="not_attempted"
        INTEGRITY_OUTCOME="not_checked"
        choose_version
        result=$?
        if [ "$result" -eq 2 ]; then
            log "Selecao cancelada; politica encerrada normalmente."
            exit 0
        elif [ "$result" -ne 0 ]; then
            show_error "Nao foi possivel ler a versao selecionada no SwiftDialog."
            exit 1
        fi
        log "Usuario selecionou Xcode $CHOSEN_VERSION ($CHOSEN_TRIGGER)"
        perform_selection "$CHOSEN_VERSION" "$CHOSEN_TRIGGER"
        result=$?
        progress_stop
        case "$result" in
            0)
                log "Selecao/CLI concluida. Integridade: $INTEGRITY_OUTCOME. Preparacao: $FIX_OUTCOME. Finder nao foi validado."
                if [ "$SELECTION_MODE" = "installed" ]; then
                    show_success_dialog "$CHOSEN_VERSION"
                fi
                break
                ;;
            3)
                log "Operacao cancelada pelo usuario antes das alteracoes"
                exit 0
                ;;
            4)
                log "XCODE_EM_USO: aguardando encerramento ou escolha do usuario."
                wait_for_xcode_close
                result=$?
                case "$result" in
                    0) log "Reabrindo seletor do Gerenciador Xcode"; continue ;;
                    2) exit 0 ;;
                    *) log "AVISO_INDISPONIVEL: encerrando politica normalmente; nenhum Xcode foi alterado."; exit 0 ;;
                esac
                ;;
            *)
                if [ "$FIX_OUTCOME" = "critical_restore_failure" ]; then
                    show_error "Nao foi possivel confirmar a restauracao do Info.plist do Xcode. O gerenciador interrompeu a operacao para proteger a instalacao. Nao altere a versao novamente antes de verificar o log /var/log/bra_xcode_manager.log."
                else
                    show_error "Nao foi possivel concluir a selecao ou instalacao do Xcode $CHOSEN_VERSION. Verifique o log /var/log/bra_xcode_manager.log."
                fi
                exit 1
                ;;
        esac
    done
}

main "$@"
