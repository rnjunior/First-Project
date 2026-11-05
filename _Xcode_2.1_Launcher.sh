#!/bin/bash
# 308_BRA_Xcode_Launcher_Fix.sh
# Fix independente para abrir Xcode antigo em macOS mais recente.
# Adaptado da ideia do projeto Xcode-launcher (MIT):
# https://github.com/IbrahimHosseini/Xcode-launcher
#
# USO: politica exclusiva no Jamf Pro / Self Service ou executar com /bin/bash.
# - Nao instala Xcode; procura versoes ja instaladas em /Applications.
# - Exibe UMA janela nativa para escolher uma versao.
# - Cria/atualiza somente ~/Applications/Xcode <versao> (Fix).app.
# - Abre o Xcode usando um wrapper com Bundle ID diferente.
# - Nao modifica Xcode.app, SIP ou xcode-select global.
# - Define DEVELOPER_DIR apenas no processo do Xcode aberto pelo launcher.
# - O uso de Xcode nao homologado pela Apple nao se torna suportado.

set -u
umask 077

PLISTBUDDY="/usr/libexec/PlistBuddy"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
BUNDLE_PREFIX="local.workplace.xcode-launcher-fix"
TEMP_DIR=""

log() {
  printf '%s | %s\n' "$(/bin/date '+%Y-%m-%d %H:%M:%S')" "$*"
}

error_ui() {
  log "ERRO: $1" >&2
  /usr/bin/osascript \
    -e 'on run argv' \
    -e 'display alert "Xcode Launcher Fix" message (item 1 of argv) as critical' \
    -e 'end run' "$1" >/dev/null 2>&1 || true
}

cleanup() {
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    /bin/rm -rf -- "$TEMP_DIR"
  fi
}
trap cleanup EXIT

# Jamf roda como root: transfere TODA a execucao para o usuario grafico.
# Isso evita criar launchers em /var/root/Applications e garante a janela
# no contexto correto da sessao do usuario.
if [[ "$EUID" -eq 0 ]]; then
  CONSOLE_USER=$(/usr/bin/stat -f '%Su' /dev/console 2>/dev/null || true)
  if [[ -z "$CONSOLE_USER" || "$CONSOLE_USER" == "root" || "$CONSOLE_USER" == "loginwindow" ]]; then
    log 'ERRO: nenhum usuario grafico conectado.' >&2
    exit 1
  fi
  CONSOLE_UID=$(/usr/bin/id -u "$CONSOLE_USER" 2>/dev/null || true)
  if [[ ! "$CONSOLE_UID" =~ ^[0-9]+$ || ! -f "$0" ]]; then
    log 'ERRO: nao foi possivel relancar o script na sessao do usuario.' >&2
    exit 1
  fi
  log "Executando no contexto de $CONSOLE_USER (UID $CONSOLE_UID)."
  /bin/launchctl asuser "$CONSOLE_UID" /usr/bin/sudo -H -u "$CONSOLE_USER" \
    /bin/bash -s -- < "$0"
  exit $?
fi

# O script deve rodar na conta do usuario para preservar seu contexto grafico.
if [[ -z "${HOME:-}" || ! -d "$HOME" ]]; then
  log 'ERRO: diretorio HOME indisponivel.' >&2
  exit 1
fi

# Descobre Xcodes reais (Bundle ID da Apple), nao confunde com os wrappers.
# Usa o Info.plist em vez do nome da pasta para lidar com Xcode.app e Xcode_XX.app.
LABELS=()
PATHS=()
VERSIONS=()
BUILDS=()
shopt -s nullglob
for xcode in /Applications/Xcode*.app; do
  [[ -d "$xcode" && -x "$xcode/Contents/MacOS/Xcode" ]] || continue
  plist="$xcode/Contents/Info.plist"
  [[ -f "$plist" ]] || continue
  bundle_id=$("$PLISTBUDDY" -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null || true)
  [[ "$bundle_id" == 'com.apple.dt.Xcode' ]] || continue
  version=$("$PLISTBUDDY" -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null || true)
  build=$("$PLISTBUDDY" -c 'Print :CFBundleVersion' "$plist" 2>/dev/null || true)
  [[ "$version" =~ ^[0-9]+(\.[0-9]+){1,4}$ ]] || continue
  [[ "$build" =~ ^[0-9]+(\.[0-9]+)*$ ]] || continue

  LABELS+=("Xcode $version (build $build) — ${xcode##*/}")
  PATHS+=("$xcode")
  VERSIONS+=("$version")
  BUILDS+=("$build")
done
shopt -u nullglob

if [[ ${#LABELS[@]} -eq 0 ]]; then
  error_ui 'Nenhuma instalação válida do Xcode foi encontrada em /Applications.'
  exit 1
fi

# Uma unica janela de selecao: sem SwiftDialog, sem janelas de progresso/sucesso.
selected=$(/usr/bin/osascript \
  -e 'on run argv' \
  -e 'set picked to choose from list argv with title "Xcode Launcher Fix" with prompt "Escolha a versão instalada do Xcode que deseja abrir:" OK button name "Abrir" cancel button name "Cancelar"' \
  -e 'if picked is false then return ""' \
  -e 'return item 1 of picked' \
  -e 'end run' \
  "${LABELS[@]}") || {
    log 'ERRO: a janela de selecao nao pôde ser exibida.' >&2
    exit 1
  }

if [[ -z "$selected" ]]; then
  log 'Operacao cancelada pelo usuario.'
  exit 0
fi

INDEX=-1
for ((i=0; i<${#LABELS[@]}; i++)); do
  if [[ "${LABELS[$i]}" == "$selected" ]]; then
    INDEX=$i
    break
  fi
done
if (( INDEX < 0 )); then
  error_ui 'A versão escolhida não foi reconhecida.'
  exit 1
fi

SOURCE_APP="${PATHS[$INDEX]}"
VERSION="${VERSIONS[$INDEX]}"
BUILD="${BUILDS[$INDEX]}"
INSTALL_DIR="$HOME/Applications"
LAUNCHER="$INSTALL_DIR/Xcode $VERSION (Fix).app"
BUNDLE_ID="$BUNDLE_PREFIX.v${VERSION//./-}.b${BUILD//./-}"

/bin/mkdir -p "$INSTALL_DIR" || {
  error_ui 'Não foi possível criar a pasta Applications do usuário.'
  exit 1
}

# Nunca exclui nem sobrescreve um aplicativo com o nome do Fix sem confirmar
# que foi criado por esta integracao.
if [[ -e "$LAUNCHER" || -L "$LAUNCHER" ]]; then
  if [[ -L "$LAUNCHER" ]]; then
    error_ui "Existe um link simbólico no destino do launcher: $LAUNCHER"
    exit 1
  fi
  existing_id=$("$PLISTBUDDY" -c 'Print :CFBundleIdentifier' "$LAUNCHER/Contents/Info.plist" 2>/dev/null || true)
  case "$existing_id" in
    "$BUNDLE_PREFIX".*) ;;
    *) error_ui "Já existe outro aplicativo no destino: $LAUNCHER"; exit 1 ;;
  esac
fi

TEMP_DIR=$(/usr/bin/mktemp -d "$INSTALL_DIR/.xcode-fix.XXXXXXXX") || {
  error_ui 'Não foi possível preparar o launcher temporário.'
  exit 1
}
TEMP_APP="$TEMP_DIR/Xcode $VERSION (Fix).app"
/bin/mkdir -p "$TEMP_APP/Contents/MacOS" "$TEMP_APP/Contents/Resources" || {
  error_ui 'Falha ao criar a estrutura do aplicativo.'
  exit 1
}

/bin/cat > "$TEMP_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>launcher</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>Xcode $VERSION (Fix)</string>
  <key>CFBundleDisplayName</key><string>Xcode $VERSION (Fix)</string>
  <key>CFBundleIconFile</key><string>Xcode</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

# Wrapper dinamico: se o Gerenciador Xcode 2.0 renomear Xcode.app, ele ainda
# encontra a MESMA versao e build pesquisando novamente o /Applications.
/bin/cat > "$TEMP_APP/Contents/MacOS/launcher" <<STUB
#!/bin/zsh
setopt null_glob
target_version="$VERSION"
target_build="$BUILD"
for xcode in /Applications/Xcode*.app; do
  [[ -x "\$xcode/Contents/MacOS/Xcode" ]] || continue
  plist="\$xcode/Contents/Info.plist"
  bundle_id=\$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "\$plist" 2>/dev/null || true)
  version=\$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "\$plist" 2>/dev/null || true)
  build=\$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "\$plist" 2>/dev/null || true)
  if [[ "\$bundle_id" == 'com.apple.dt.Xcode' && "\$version" == "\$target_version" && "\$build" == "\$target_build" ]]; then
    # Aplica a toolchain deste Xcode somente ao app e seus subprocessos.
    # Nao altera a selecao de desenvolvimento global do Mac.
    if [[ ! -d "\$xcode/Contents/Developer" ]]; then
      /usr/bin/osascript -e 'display alert "Xcode Launcher Fix" message "A pasta Contents/Developer não foi encontrada na versão selecionada." as critical' >/dev/null 2>&1 || true
      exit 1
    fi
    export DEVELOPER_DIR="\$xcode/Contents/Developer"
    exec "\$xcode/Contents/MacOS/Xcode" "\$@"
  fi
done
/usr/bin/osascript -e 'display alert "Xcode Launcher Fix" message "A versão escolhida não foi encontrada. Abra o Fix novamente para selecionar outro Xcode." as critical' >/dev/null 2>&1 || true
exit 1
STUB
/bin/chmod 755 "$TEMP_APP/Contents/MacOS/launcher"

if [[ -f "$SOURCE_APP/Contents/Resources/Xcode.icns" ]]; then
  /bin/cp "$SOURCE_APP/Contents/Resources/Xcode.icns" "$TEMP_APP/Contents/Resources/Xcode.icns" || true
fi

if ! /usr/bin/plutil -lint "$TEMP_APP/Contents/Info.plist" >/dev/null 2>&1; then
  error_ui 'O Info.plist gerado não passou na validação.'
  exit 1
fi

if ! /usr/bin/codesign --force --deep --sign - "$TEMP_APP" >/dev/null 2>&1; then
  log 'AVISO: assinatura ad-hoc não concluída. O macOS pode impedir a abertura.'
fi

if [[ -e "$LAUNCHER" ]]; then
  /bin/rm -rf -- "$LAUNCHER" || {
    error_ui 'Não foi possível substituir o launcher anterior.'
    exit 1
  }
fi
/bin/mv "$TEMP_APP" "$LAUNCHER" || {
  error_ui 'Não foi possível salvar o launcher na pasta do usuário.'
  exit 1
}

if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$LAUNCHER" >/dev/null 2>&1 || true
fi

log "Launcher gerado: $LAUNCHER"
log "Xcode selecionado: $SOURCE_APP (versão $VERSION, build $BUILD)"
if ! /usr/bin/open -a "$LAUNCHER"; then
  error_ui 'Falha ao abrir o launcher. Consulte o log da política no Jamf.'
  exit 1
fi
log 'Comando de abertura enviado. DEVELOPER_DIR é definido no launcher; Xcode original e xcode-select global permanecem inalterados.'
exit 0
