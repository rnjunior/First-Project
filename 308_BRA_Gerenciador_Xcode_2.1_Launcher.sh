#!/bin/bash
# Gerenciador Xcode 2.1 - Jamf Pro + SwiftDialog + Launcher por usuario
# Adaptacao do conceito Xcode-launcher (Ibrahim Hosseini, MIT, 2026):
# https://github.com/IbrahimHosseini/Xcode-launcher
#
# NOTAS:
# - Nao altera Xcode original para contornar bloqueios do macOS.
# - Launcher somente abre GUI; nao muda xcode-select automaticamente.
# - A compatibilidade entre Xcode antigo/macOS novo NAO e suportada pela Apple.
# - Os triggers de instalacao abaixo precisam existir no Jamf Pro.

set -u
umask 077

DIALOG="/usr/local/bin/dialog"
JAMF="/usr/local/bin/jamf"
PLISTBUDDY="/usr/libexec/PlistBuddy"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
ICON_URL="https://usw2.ics.services.jamfcloud.com/icon/hash_34643aa5722dd94f45ffd8102dd67e8fb135eede6a855c578a9c9b866b543cc6"
LOG="/var/log/xcode_manager.log"
LAUNCHER_PREFIX="com.santander.workplace.xcode-launcher"

XCODE_VERSIONS=(
  "Xcode 16.4:Xcode16.4"
  "Xcode 26.0.1:Xcode26.0.1"
  "Xcode 26.1.1:Xcode26.1.1"
  "Xcode 26.2:Xcode26.2"
  "Xcode 26.3:Xcode26.3"
)

DIALOG_FILE=""
PROGRESS_PID=""
CONSOLE_USER=""
CONSOLE_UID=""
CONSOLE_HOME=""

log() { /bin/echo "$(/bin/date '+%Y-%m-%d %H:%M:%S') | $*" >> "$LOG"; }

cleanup() {
  if [[ -n "$DIALOG_FILE" && -f "$DIALOG_FILE" ]]; then
    /bin/echo 'quit:' >> "$DIALOG_FILE"
    /bin/rm -f "$DIALOG_FILE"
  fi
}
trap cleanup EXIT

error_dialog() {
  log "ERRO: $1"
  "$DIALOG" --title "Gerenciador Xcode - Erro" \
    --icon "$ICON_URL" --overlayicon caution \
    --message "$1" --button1text "OK" --ontop >/dev/null 2>&1 || true
}

info_dialog() {
  "$DIALOG" --title "Gerenciador Xcode" \
    --icon "$ICON_URL" --message "$1" \
    --button1text "OK" --ontop >/dev/null 2>&1 || true
}

# Recebe saida do SwiftDialog e devolve uma linha SelectedOption.
selected_option() {
  /usr/bin/awk -F'"' '/SelectedOption/ { print $4; exit }'
}

find_console_user() {
  CONSOLE_USER=$(/usr/bin/stat -f '%Su' /dev/console 2>/dev/null || true)
  if [[ -z "$CONSOLE_USER" || "$CONSOLE_USER" == "root" || "$CONSOLE_USER" == "loginwindow" ]]; then
    error_dialog "Nenhum usuario grafico conectado. Abra o gerenciador durante uma sessao de usuario."
    return 1
  fi
  CONSOLE_UID=$(/usr/bin/id -u "$CONSOLE_USER" 2>/dev/null || true)
  CONSOLE_HOME=$(/usr/bin/dscl . -read "/Users/$CONSOLE_USER" NFSHomeDirectory 2>/dev/null | /usr/bin/sed -n 's/^NFSHomeDirectory: //p' | /usr/bin/head -n 1)
  if [[ -z "$CONSOLE_UID" || -z "$CONSOLE_HOME" || ! -d "$CONSOLE_HOME" ]]; then
    error_dialog "Nao foi possivel localizar o home do usuario conectado."
    return 1
  fi
  log "Usuario console: $CONSOLE_USER"
}

# Le versao e valida que o .app e realmente um Xcode da Apple.
read_xcode_version() {
  local app="$1" bundle_id version
  [[ -x "$app/Contents/MacOS/Xcode" ]] || return 1
  bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null) || return 1
  [[ "$bundle_id" == "com.apple.dt.Xcode" ]] || return 1
  version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist" 2>/dev/null) || return 1
  [[ -n "$version" ]] || return 1
  /bin/echo "$version"
}

# Procura qualquer nome Xcode*.app; tambem encontra Xcode.app renomeado.
# Da prioridade a caminhos nomeados por versao, reduzindo ambiguidade.
find_installed_xcode() {
  local version="$1" path got
  shopt -s nullglob
  for path in "/Applications/Xcode_${version}.app" \
              "/Applications/Xcode-${version}.app" \
              /Applications/Xcode_*.app \
              /Applications/Xcode-*.app \
              /Applications/Xcode.app; do
    [[ -d "$path" ]] || continue
    got=$(read_xcode_version "$path" 2>/dev/null) || continue
    if [[ "$got" == "$version" ]]; then
      /bin/echo "$path"
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob
  return 1
}

# Cria um app independente por usuario. O stub resolve o Xcode na HORA de abrir,
# de forma que trocar Xcode.app <-> Xcode_<versao>.app nao quebra o launcher.
create_launcher() {
  local version="$1" source_app="$2" install_dir app bundle_id existing_id stub
  [[ "$version" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]] || { error_dialog "Versao invalida: $version"; return 1; }
  install_dir="$CONSOLE_HOME/Applications"
  if [[ ! -d "$install_dir" ]]; then
    /usr/bin/sudo -u "$CONSOLE_USER" /bin/mkdir -p "$install_dir" || { error_dialog "Nao foi possivel criar $install_dir."; return 1; }
  fi
  app="$install_dir/Xcode $version (Launcher).app"
  bundle_id="$LAUNCHER_PREFIX.${version//./-}"

  if [[ -e "$app" ]]; then
    existing_id=$($PLISTBUDDY -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true)
    if [[ "$existing_id" != "$bundle_id" ]]; then
      error_dialog "Ja existe um aplicativo com esse nome, mas ele nao pertence ao gerenciador: $app"
      return 1
    fi
    /bin/rm -rf -- "$app" || { error_dialog "Nao foi possivel atualizar o launcher existente."; return 1; }
  fi

  /bin/mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" || return 1
  /bin/cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>launcher</string>
  <key>CFBundleIdentifier</key><string>$bundle_id</string>
  <key>CFBundleName</key><string>Xcode $version (Launcher)</string>
  <key>CFBundleDisplayName</key><string>Xcode $version (Launcher)</string>
  <key>CFBundleIconFile</key><string>Xcode</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST

  stub="$app/Contents/MacOS/launcher"
  /bin/cat > "$stub" <<'STUB'
#!/bin/zsh
# Resolve a versao no momento da execucao (nao depende de caminho fixo).
setopt null_glob
version="__TARGET_VERSION__"
for xcode in "/Applications/Xcode_${version}.app" \
             "/Applications/Xcode-${version}.app" \
             /Applications/Xcode_*.app \
             /Applications/Xcode-*.app \
             /Applications/Xcode.app; do
  [[ -x "$xcode/Contents/MacOS/Xcode" ]] || continue
  bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$xcode/Contents/Info.plist" 2>/dev/null || true)
  found_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$xcode/Contents/Info.plist" 2>/dev/null || true)
  if [[ "$bundle_id" == "com.apple.dt.Xcode" && "$found_version" == "$version" ]]; then
    exec "$xcode/Contents/MacOS/Xcode" "$@"
  fi
done
/usr/bin/osascript -e 'display alert "Gerenciador Xcode" message "A versao solicitada do Xcode nao foi encontrada em /Applications." as critical'
exit 1
STUB
  /usr/bin/sed -i '' "s/__TARGET_VERSION__/$version/g" "$stub" || return 1
  /bin/chmod 755 "$stub"

  if [[ -f "$source_app/Contents/Resources/Xcode.icns" ]]; then
    /bin/cp "$source_app/Contents/Resources/Xcode.icns" "$app/Contents/Resources/Xcode.icns" || true
  fi

  if ! /usr/bin/codesign --force --deep --sign - "$app" >/dev/null 2>&1; then
    log "AVISO: assinatura ad-hoc do launcher falhou: $app"
  fi
  /usr/sbin/chown -R "$CONSOLE_USER" "$app" || return 1
  if [[ -x "$LSREGISTER" ]]; then
    /bin/launchctl asuser "$CONSOLE_UID" /usr/bin/sudo -u "$CONSOLE_USER" "$LSREGISTER" -f "$app" >/dev/null 2>&1 || true
  fi
  log "Launcher gerado: $app"
  /bin/echo "$app"
}

open_legacy_xcode() {
  local version="$1" xcode_path launcher
  xcode_path=$(find_installed_xcode "$version") || { error_dialog "Xcode $version nao encontrado."; return 1; }
  launcher=$(create_launcher "$version" "$xcode_path") || return 1
  log "Abrindo Xcode $version via launcher ($launcher)"
  if ! /bin/launchctl asuser "$CONSOLE_UID" /usr/bin/sudo -u "$CONSOLE_USER" \
      /usr/bin/open -a "$launcher"; then
    error_dialog "Nao foi possivel solicitar a abertura do launcher para Xcode $version."
    return 1
  fi
  return 0
}

set_cli_xcode() {
  local version="$1" xcode_path
  xcode_path=$(find_installed_xcode "$version") || { error_dialog "Xcode $version nao encontrado."; return 1; }
  if ! /usr/bin/xcode-select -s "$xcode_path/Contents/Developer"; then
    error_dialog "Falha ao definir o Xcode $version como toolchain CLI."
    return 1
  fi
  log "CLI alterada para: $xcode_path/Contents/Developer"
  info_dialog "Xcode $version definido como **toolchain de linha de comando**.\n\nIsso nao contorna o bloqueio grafico. Use 'Abrir pelo launcher' para abrir o aplicativo."
}

# Nao apaga/sobrescreve a versao que estava em Xcode.app antes de instalar outra.
# Se era a CLI global, atualiza xcode-select para o novo caminho preservado.
preserve_xcode_before_install() {
  local desired_version="$1" current_app="/Applications/Xcode.app" old_version saved_path previous_developer
  [[ -d "$current_app" ]] || return 0
  old_version=$(read_xcode_version "$current_app") || { error_dialog "Xcode.app atual nao passou na validacao; instalacao interrompida."; return 1; }
  [[ "$old_version" == "$desired_version" ]] && return 0

  saved_path="/Applications/Xcode_${old_version}.app"
  if [[ -e "$saved_path" ]]; then
    error_dialog "Nao vou substituir o Xcode.app: o destino $saved_path ja existe. Resolva a duplicidade manualmente."
    return 1
  fi
  if /usr/bin/pgrep -x Xcode >/dev/null 2>&1; then
    error_dialog "Feche todas as instancias do Xcode antes de instalar outra versao."
    return 1
  fi

  previous_developer=$(/usr/bin/xcode-select -p 2>/dev/null || true)
  if ! /bin/mv "$current_app" "$saved_path"; then
    error_dialog "Nao foi possivel preservar a instalacao atual em $saved_path."
    return 1
  fi
  log "Preservado $current_app -> $saved_path"
  if [[ "$previous_developer" == "$current_app/Contents/Developer" ]]; then
    if ! /usr/bin/xcode-select -s "$saved_path/Contents/Developer"; then
      /bin/mv "$saved_path" "$current_app" 2>/dev/null || true
      error_dialog "Falha ao preservar a toolchain ativa; instalacao interrompida."
      return 1
    fi
  fi
  return 0
}

# Verifica tanto o exit code do Jamf quanto a instalacao real.
install_xcode() {
  local version="$1" trigger="$2" output status installed
  [[ -x "$JAMF" ]] || { error_dialog "Binario Jamf nao encontrado em $JAMF"; return 1; }
  [[ "$(/usr/bin/id -u)" == "0" ]] || { error_dialog "A instalacao precisa executar como root (Jamf Pro)."; return 1; }

  preserve_xcode_before_install "$version" || return 1
  DIALOG_FILE=$(/usr/bin/mktemp /var/tmp/xcode_dialog.XXXXXX) || return 1
  output=$(/usr/bin/mktemp /var/tmp/xcode_policy.XXXXXX) || return 1

  "$DIALOG" --mini --title "Instalando Xcode $version" --icon "$ICON_URL" \
    --message "Instalacao via Jamf Pro em andamento..." \
    --progress --progresstext "Executando politica $trigger" \
    --commandfile "$DIALOG_FILE" --ontop --position bottomright &
  PROGRESS_PID=$!

  log "Iniciando evento Jamf: $trigger"
  "$JAMF" policy -event "$trigger" > "$output" 2>&1 &
  local jamf_pid=$!
  /bin/echo 'progress: 10' >> "$DIALOG_FILE"
  wait "$jamf_pid"
  status=$?
  /bin/echo 'progress: 100' >> "$DIALOG_FILE"
  /bin/echo 'quit:' >> "$DIALOG_FILE"
  wait "$PROGRESS_PID" 2>/dev/null || true
  PROGRESS_PID=""
  /bin/rm -f "$DIALOG_FILE"
  DIALOG_FILE=""

  log "Evento Jamf $trigger encerrado com status $status. Saida em $output"
  if [[ $status -ne 0 ]]; then
    error_dialog "Falha no evento Jamf '$trigger' (codigo $status). Verifique $output e /var/log/jamf.log."
    return 1
  fi

  installed=$(find_installed_xcode "$version") || {
    error_dialog "O Jamf retornou sucesso, mas o Xcode $version nao foi encontrado em /Applications. Consulte $output."
    return 1
  }
  log "Instalado/verificado: $installed"
  /bin/rm -f "$output"
  return 0
}

action_menu() {
  local version="$1" output action
  output=$("$DIALOG" --title "Xcode $version - Acoes" \
    --message "Selecione a operacao. **Abrir via launcher** nao altera o Xcode padrao.\n\n**Definir toolchain CLI** altera globalmente o xcode-select.\n\nEm versoes antigas nao execute xcodebuild -runFirstLaunch nem instale componentes adicionais." \
    --icon "$ICON_URL" --selecttitle "Acao",radio \
    --selectvalues "Abrir via launcher,Definir toolchain CLI" \
    --button1text "Executar" --button2text "Cancelar" \
    --width 650 --height 370 --ontop --output) || return 0
  action=$(printf '%s\n' "$output" | selected_option)
  case "$action" in
    "Abrir via launcher") open_legacy_xcode "$version" ;;
    "Definir toolchain CLI") set_cli_xcode "$version" ;;
    *) return 0 ;;
  esac
}

main() {
  local display_values="" item version trigger installed output choice found="" v
  [[ -x "$DIALOG" ]] || { /bin/echo "SwiftDialog nao encontrado: $DIALOG" >&2; return 1; }
  find_console_user || return 1
  log "=== Gerenciador Xcode 2.1 iniciado ==="

  for item in "${XCODE_VERSIONS[@]}"; do
    version="${item%%:*}"
    if find_installed_xcode "${version#Xcode }" >/dev/null 2>&1; then
      version="$version (instalado)"
    fi
    [[ -n "$display_values" ]] && display_values+=","
    display_values+="$version"
  done

  output=$("$DIALOG" --title "Gerenciador Xcode" \
    --message "Selecione uma versao para instalar, abrir via launcher ou alterar a toolchain CLI." \
    --icon "$ICON_URL" --selecttitle "Versoes do Xcode",radio \
    --selectvalues "$display_values" --button1text "Selecionar" \
    --button2text "Cancelar" --width 650 --height 370 --ontop --output) || return 0
  choice=$(printf '%s\n' "$output" | selected_option)
  [[ -n "$choice" ]] || return 0
  choice="${choice% (instalado)}"

  for item in "${XCODE_VERSIONS[@]}"; do
    version="${item%%:*}"
    trigger="${item#*:}"
    if [[ "$choice" == "$version" ]]; then
      found="true"
      break
    fi
  done
  [[ "$found" == "true" ]] || { error_dialog "Opcao desconhecida: $choice"; return 1; }

  v="${version#Xcode }"
  if ! installed=$(find_installed_xcode "$v"); then
    install_xcode "$v" "$trigger" || return 1
  else
    log "Xcode $v ja presente: $installed"
  fi
  action_menu "$v"
}

main "$@"
