#Requires -Version 5.1
<#
================================================================================
  ReconectarWifi.ps1
  Mantem viva a sessao do Wi-Fi corporativo (portal cativo Zoox/ZooxWiFi)
  para que o tunel (tunn.dev) e as impressoras Zebra nao percam conexao.

  O QUE ELE FAZ
   - Deixa voce escolher o Wi-Fi de uma LISTA (e salva a escolha).
   - Fica monitorando a internet a cada N segundos.
   - Quando o portal cativo derruba a sessao (a cada ~12h), ele:
        1) reconecta no Wi-Fi escolhido (se precisar),
        2) pega a URL ATUAL do portal (nao a antiga - os parametros mudam),
        3) tenta fazer o login/"Proximo" automaticamente,
        4) confirma se a internet voltou.
   - Grava LOG COMPLETO de tudo (inclusive erros) num arquivo facil de copiar.

  COMO USAR (abra o PowerShell na pasta deste arquivo)
     Configurar o Wi-Fi (menu):      .\ReconectarWifi.ps1 -Configurar
     Testar 1 vez agora:             .\ReconectarWifi.ps1 -Verificar
     Rodar o monitor (fica ligado):  .\ReconectarWifi.ps1
     Capturar o portal p/ enviar:    .\ReconectarWifi.ps1 -Capturar
     Ver as ultimas linhas do log:   .\ReconectarWifi.ps1 -Logs 100

  Se o Windows bloquear a execucao, rode antes (so nesta janela):
     Set-ExecutionPolicy -Scope Process -Bypass
================================================================================
#>

[CmdletBinding()]
param(
    [switch] $Configurar,     # abre o menu de selecao de Wi-Fi
    [switch] $Verificar,      # faz uma unica verificacao e sai
    [switch] $Capturar,       # baixa a pagina do portal e salva tudo p/ me enviar
    [int]    $Logs = 0,       # mostra as ultimas N linhas do log e sai
    [int]    $Intervalo = 0,  # sobrescreve o intervalo (segundos)
    [switch] $SemReconectar   # nao tenta reconectar o Wi-Fi automaticamente
)

# ------------------------------------------------------------------ Setup base
$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls } catch {}

$script:Raiz    = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$script:PastaLog = Join-Path $script:Raiz 'Logs'
$script:ArqConfig = Join-Path $script:Raiz 'config.json'
if (-not (Test-Path $script:PastaLog)) { New-Item -ItemType Directory -Path $script:PastaLog -Force | Out-Null }
$script:ArqLog  = Join-Path $script:PastaLog ("reconect-{0}.log" -f (Get-Date -Format 'yyyy-MM-dd'))

# ------------------------------------------------------------------ Logging
function Write-Log {
    param(
        [string] $Msg,
        [ValidateSet('INFO','OK','AVISO','ERRO','DEBUG','PASSO')] [string] $Nivel = 'INFO'
    )
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $linha = "[{0}] [{1,-5}] {2}" -f $ts, $Nivel, $Msg
    try { Add-Content -Path $script:ArqLog -Value $linha -Encoding UTF8 } catch {}
    $cor = switch ($Nivel) {
        'OK'    { 'Green' }
        'AVISO' { 'Yellow' }
        'ERRO'  { 'Red' }
        'DEBUG' { 'DarkGray' }
        'PASSO' { 'Cyan' }
        default { 'Gray' }
    }
    Write-Host $linha -ForegroundColor $cor
}

function Write-LogErro {
    # Registra um erro com TODOS os detalhes, num bloco facil de copiar e me enviar.
    param([System.Management.Automation.ErrorRecord] $Err, [string] $Contexto = '')
    $sep = '================= ERRO (copie deste bloco ate o fim) ================='
    Write-Log $sep 'ERRO'
    if ($Contexto) { Write-Log ("Contexto : {0}" -f $Contexto) 'ERRO' }
    Write-Log ("Mensagem : {0}" -f $Err.Exception.Message) 'ERRO'
    Write-Log ("Tipo     : {0}" -f $Err.Exception.GetType().FullName) 'ERRO'
    if ($Err.Exception.Response) {
        try {
            $r = $Err.Exception.Response
            Write-Log ("HTTP     : {0} {1}" -f [int]$r.StatusCode, $r.StatusCode) 'ERRO'
            if ($r.Headers['Location']) { Write-Log ("Location : {0}" -f $r.Headers['Location']) 'ERRO' }
        } catch {}
    }
    if ($Err.InvocationInfo) {
        Write-Log ("Local    : linha {0}: {1}" -f $Err.InvocationInfo.ScriptLineNumber, ($Err.InvocationInfo.Line).Trim()) 'ERRO'
    }
    Write-Log ("Pilha    : {0}" -f ($Err.ScriptStackTrace -replace "`r?`n", ' | ')) 'ERRO'
    Write-Log '=====================================================================' 'ERRO'
}

# ------------------------------------------------------------------ Config
function Get-ConfigPadrao {
    [pscustomobject]@{
        SSID              = ''
        IntervaloSegundos = 30
        SondaUrl          = 'http://www.msftconnecttest.com/connecttest.txt'
        SondaTextoOk      = 'Microsoft Connect Test'
        SondaRedirectUrl  = 'http://www.msftconnecttest.com/redirect'
        PortalHostContem  = 'zooxwifi.com'
        ReconectarWifi    = $true
        LoginReplay       = $null   # preenchido por mim depois da captura, se necessario
        UltimaAtualizacao = (Get-Date).ToString('s')
    }
}

function Carregar-Config {
    if (Test-Path $script:ArqConfig) {
        try {
            $raw = Get-Content $script:ArqConfig -Raw -Encoding UTF8
            $cfg = $raw | ConvertFrom-Json
            # completa campos que faltarem (compatibilidade futura)
            $padrao = Get-ConfigPadrao
            foreach ($p in $padrao.PSObject.Properties) {
                if (-not ($cfg.PSObject.Properties.Name -contains $p.Name)) {
                    $cfg | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
                }
            }
            return $cfg
        } catch {
            Write-LogErro $_ "Config corrompida em $script:ArqConfig - usando padrao"
            return Get-ConfigPadrao
        }
    }
    return Get-ConfigPadrao
}

function Salvar-Config {
    param($Cfg)
    $Cfg.UltimaAtualizacao = (Get-Date).ToString('s')
    $Cfg | ConvertTo-Json -Depth 8 | Set-Content -Path $script:ArqConfig -Encoding UTF8
    Write-Log ("Config salva em: {0}" -f $script:ArqConfig) 'OK'
}

# ------------------------------------------------------------------ Wi-Fi
function Get-WifiAdapter {
    # Objeto do adaptador Wi-Fi via cmdlets nativos (funciona mesmo se netsh wlan estiver bloqueado).
    try {
        $cands = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
            $_.PhysicalMediaType -match '802\.11' -or
            $_.InterfaceDescription -match 'Wi-?Fi|Wireless|WLAN|802\.11' -or
            $_.Name -match 'Wi-?Fi|Wireless'
        }
        $up = $cands | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
        if ($up) { return $up }
        if ($cands) { return ($cands | Select-Object -First 1) }
    } catch {}
    return $null
}

function Get-WifiInterface {
    # Nome do adaptador Wi-Fi (ou $null).
    $a = Get-WifiAdapter
    if ($a) { return $a.Name }
    try {
        $saida = netsh wlan show interfaces 2>$null
        $nome = ($saida | Select-String -Pattern '^\s*(Nome|Name)\s*:\s*(.+)$' | Select-Object -First 1)
        if ($nome) { return $nome.Matches[0].Groups[2].Value.Trim() }
    } catch {}
    return $null
}

function Get-WifiAtual {
    # Nome da rede (SSID) conectada agora. Usa Get-NetConnectionProfile (camada de rede,
    # independe do servico WLAN AutoConfig); cai para netsh so se precisar.
    try {
        $a = Get-WifiAdapter
        if ($a) {
            $prof = Get-NetConnectionProfile -InterfaceIndex $a.ifIndex -ErrorAction SilentlyContinue
            if ($prof) { return ($prof | Select-Object -First 1).Name }
        }
    } catch {}
    try {
        $saida = netsh wlan show interfaces 2>$null
        $linha = $saida | Select-String -Pattern '^\s*SSID\s*:\s*(.+)$' | Select-Object -First 1
        if ($linha) { return $linha.Matches[0].Groups[1].Value.Trim() }
    } catch {}
    return $null
}

function Get-RedesVisiveis {
    # SSIDs que estao no alcance agora (keyword "SSID" e estavel em qualquer idioma).
    $lista = @()
    try {
        $saida = netsh wlan show networks 2>$null
        foreach ($m in ([regex]::Matches(($saida -join "`n"), '(?m)^\s*SSID\s+\d+\s*:\s*(.+)$'))) {
            $s = $m.Groups[1].Value.Trim()
            if ($s -and ($lista -notcontains $s)) { $lista += $s }
        }
    } catch {}
    return $lista
}

function Get-PerfisSalvos {
    # Perfis Wi-Fi ja salvos no Windows.
    $lista = @()
    try {
        $saida = netsh wlan show profiles 2>$null
        foreach ($linha in $saida) {
            if ($linha -match ':\s*(.+)$' -and ($linha -match 'Perfil|Profile')) {
                $s = ($Matches[1]).Trim()
                if ($s -and ($lista -notcontains $s)) { $lista += $s }
            }
        }
    } catch {}
    return $lista
}

function Selecionar-Wifi {
    param($Cfg)
    Write-Log 'Abrindo menu de selecao de Wi-Fi...' 'PASSO'

    $adapt = Get-WifiInterface
    if ($adapt) { Write-Log ("Adaptador Wi-Fi detectado: {0}" -f $adapt) 'INFO' }
    else { Write-Log 'Nenhum adaptador Wi-Fi detectado. (Tudo bem: o monitor funciona so mantendo o portal vivo.)' 'AVISO' }

    $atualConn = Get-WifiAtual
    if ($atualConn) { Write-Log ("Rede conectada agora: '{0}'" -f $atualConn) 'INFO' }

    $visiveis = Get-RedesVisiveis
    $perfis   = Get-PerfisSalvos
    $todas = @()
    foreach ($s in (@($atualConn) + $visiveis + $perfis)) { if ($s -and ($todas -notcontains $s)) { $todas += $s } }

    if ($todas.Count -eq 0) {
        Write-Log 'Nao consegui listar redes pelo Windows (netsh/WLAN pode estar bloqueado nesta maquina).' 'AVISO'
        Write-Log 'Sem problema: o monitor so precisa do portal. Pode deixar em branco.' 'INFO'
        $manual = Read-Host 'Digite o NOME do Wi-Fi (SSID) ou pressione ENTER para nao gerenciar Wi-Fi'
        $Cfg.SSID = $manual.Trim()
        $Cfg.ReconectarWifi = [bool]$Cfg.SSID
        Salvar-Config $Cfg
        return $Cfg
    }

    Write-Host ''
    Write-Host '  ===== REDES =====' -ForegroundColor Cyan
    for ($i = 0; $i -lt $todas.Count; $i++) {
        $marca = ''
        if ($todas[$i] -eq $atualConn)      { $marca += ' [conectada agora]' }
        if ($visiveis -contains $todas[$i]) { $marca += ' [no alcance]' }
        if ($perfis   -contains $todas[$i]) { $marca += ' [salva]' }
        Write-Host ("   {0,2}) {1}{2}" -f ($i + 1), $todas[$i], $marca)
    }
    Write-Host '    0) (nao gerenciar Wi-Fi - so manter o portal vivo)'
    Write-Host ''
    $esc = Read-Host 'Escolha o numero (ou o nome exato). ENTER usa a rede conectada agora'
    $escolhido = $null
    if ([string]::IsNullOrWhiteSpace($esc)) { $escolhido = $atualConn }
    elseif ($esc -eq '0') { $escolhido = '' }
    elseif ($esc -match '^\d+$') {
        $idx = [int]$esc - 1
        if ($idx -ge 0 -and $idx -lt $todas.Count) { $escolhido = $todas[$idx] }
    } else { $escolhido = $esc.Trim() }

    $Cfg.SSID = [string]$escolhido
    $Cfg.ReconectarWifi = [bool]$Cfg.SSID
    Salvar-Config $Cfg
    if ($Cfg.SSID) { Write-Log ("Wi-Fi escolhido e salvo: '{0}'" -f $Cfg.SSID) 'OK' }
    else { Write-Log 'Salvo: nao gerenciar Wi-Fi (so manter o portal vivo).' 'OK' }
    return $Cfg
}

function Conectar-Wifi {
    param([string] $SSID)
    if (-not $SSID) { return $false }
    Write-Log ("Tentando conectar no Wi-Fi '{0}'..." -f $SSID) 'PASSO'
    try {
        $r = netsh wlan connect name="$SSID" 2>&1
        Write-Log ("netsh: {0}" -f ($r -join ' ')) 'DEBUG'
        Start-Sleep -Seconds 6
        $atual = Get-WifiAtual
        if ($atual -eq $SSID) { Write-Log ("Conectado em '{0}'." -f $SSID) 'OK'; return $true }
        Write-Log ("Ainda nao conectado (SSID atual: '{0}')." -f $atual) 'AVISO'
        return $false
    } catch {
        Write-LogErro $_ "Falha ao conectar no Wi-Fi '$SSID'"
        return $false
    }
}

# ------------------------------------------------------------------ Rede/HTTP
function Invoke-Probe {
    # Faz UM request sem seguir redirect, devolvendo status/location/body mesmo em erro.
    param([string] $Url, [int] $TimeoutSec = 8)
    try {
        $r = Invoke-WebRequest -Uri $Url -MaximumRedirection 0 -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
        $loc = $null; try { $loc = $r.Headers.Location } catch {}
        return [pscustomobject]@{ Status = [int]$r.StatusCode; Location = $loc; Body = $r.Content; Erro = $null }
    } catch {
        $resp = $null; try { $resp = $_.Exception.Response } catch {}
        if ($resp) {
            $status = 0; try { $status = [int]$resp.StatusCode } catch {}
            $loc = $null; try { $loc = $resp.Headers['Location'] } catch {}
            $body = $null
            try { $sr = New-Object IO.StreamReader($resp.GetResponseStream()); $body = $sr.ReadToEnd(); $sr.Close() } catch {}
            return [pscustomobject]@{ Status = $status; Location = $loc; Body = $body; Erro = $null }
        }
        return [pscustomobject]@{ Status = 0; Location = $null; Body = $null; Erro = $_.Exception.Message }
    }
}

function Testar-Conexao {
    # Devolve: @{ Estado = 'ONLINE'|'CATIVO'|'OFFLINE'; PortalUrl = '...' }
    param($Cfg)
    $p = Invoke-Probe -Url $Cfg.SondaUrl
    if ($p.Status -eq 200 -and $p.Body -and ($p.Body -match [regex]::Escape($Cfg.SondaTextoOk))) {
        return @{ Estado = 'ONLINE'; PortalUrl = $null }
    }
    # Procura a URL FRESCA do portal via sonda de redirect
    $portal = $null
    if ($p.Status -ge 300 -and $p.Status -lt 400 -and $p.Location) { $portal = $p.Location }
    if (-not $portal) {
        $p2 = Invoke-Probe -Url $Cfg.SondaRedirectUrl
        if ($p2.Status -ge 300 -and $p2.Status -lt 400 -and $p2.Location) { $portal = $p2.Location }
        elseif ($p2.Body -and $p2.Body -match 'https?://[^"'' ]*zooxwifi[^"'' ]*') { $portal = $Matches[0] }
    }
    if (-not $portal -and $p.Body -and $p.Body -match 'https?://[^"'' ]*zooxwifi[^"'' ]*') { $portal = $Matches[0] }

    if ($portal -or ($p.Status -ge 300 -and $p.Status -lt 400) -or ($p.Status -eq 200)) {
        return @{ Estado = 'CATIVO'; PortalUrl = $portal }
    }
    return @{ Estado = 'OFFLINE'; PortalUrl = $null }
}

function ConvertTo-UrlAbsoluta {
    param([string] $Base, [string] $Ref)
    try { return ([Uri]::new([Uri]$Base, $Ref)).AbsoluteUri } catch { return $Ref }
}

function Get-Formularios {
    # Extrai formularios (action/method/inputs) do HTML por regex (sem depender de IE).
    param([string] $Html, [string] $BaseUrl)
    $forms = @()
    foreach ($mf in [regex]::Matches($Html, '(?is)<form\b([^>]*)>(.*?)</form>')) {
        $attrs = $mf.Groups[1].Value
        $corpo = $mf.Groups[2].Value
        $action = ''; if ($attrs -match '(?i)action\s*=\s*["'']?([^"''\s>]+)') { $action = $Matches[1] }
        $method = 'GET'; if ($attrs -match '(?i)method\s*=\s*["'']?(get|post)') { $method = $Matches[1].ToUpper() }
        $inputs = @{}
        foreach ($mi in [regex]::Matches($corpo, '(?is)<input\b([^>]*)>')) {
            $ia = $mi.Groups[1].Value
            $nome = ''; if ($ia -match '(?i)name\s*=\s*["'']?([^"''\s>]+)') { $nome = $Matches[1] }
            $val = '';  if ($ia -match '(?i)value\s*=\s*["'']([^"'']*)["'']') { $val = $Matches[1] } elseif ($ia -match '(?i)value\s*=\s*([^"''\s>]+)') { $val = $Matches[1] }
            if ($nome) { $inputs[$nome] = $val }
        }
        $forms += [pscustomobject]@{
            ActionAbs = (ConvertTo-UrlAbsoluta -Base $BaseUrl -Ref $action)
            Method    = $method
            Inputs    = $inputs
        }
    }
    return $forms
}

function Invoke-Login {
    # Tenta autorizar a sessao. Estrategias, em ordem:
    #   1) LoginReplay configurado (request exato que eu monto apos a captura)
    #   2) Submeter automaticamente o formulario da pagina do portal
    #   3) Seguir link de redirecionamento/meta-refresh
    param($Cfg, [string] $PortalUrl)

    # --- Estrategia 1: replay configurado ---
    if ($Cfg.LoginReplay) {
        try {
            Write-Log 'Login via replay configurado...' 'PASSO'
            $lr = $Cfg.LoginReplay
            $hdr = @{}; if ($lr.Headers) { $lr.Headers.PSObject.Properties | ForEach-Object { $hdr[$_.Name] = $_.Value } }
            $args = @{ Uri = $lr.Url; Method = $lr.Method; UseBasicParsing = $true; TimeoutSec = 15; Headers = $hdr }
            if ($lr.Body) { $args.Body = $lr.Body }
            if ($lr.ContentType) { $args.ContentType = $lr.ContentType }
            $r = Invoke-WebRequest @args
            Write-Log ("Replay respondeu HTTP {0}, URL final {1}" -f [int]$r.StatusCode, $r.BaseResponse.ResponseUri) 'OK'
            return $true
        } catch { Write-LogErro $_ 'Falha no login via replay' }
    }

    if (-not $PortalUrl) {
        Write-Log 'Sem URL do portal e sem replay configurado. Nao da para logar automaticamente ainda.' 'AVISO'
        Write-Log 'Rode: .\ReconectarWifi.ps1 -Capturar  e me envie o arquivo gerado.' 'AVISO'
        return $false
    }

    # --- Estrategia 2: baixar a pagina e submeter o formulario ---
    try {
        Write-Log ("Abrindo pagina do portal: {0}" -f $PortalUrl) 'PASSO'
        $pg = Invoke-WebRequest -Uri $PortalUrl -UseBasicParsing -TimeoutSec 15 -MaximumRedirection 5
        $baseUrl = $PortalUrl
        try { if ($pg.BaseResponse.ResponseUri) { $baseUrl = $pg.BaseResponse.ResponseUri.AbsoluteUri } } catch {}
        $html = $pg.Content
        Write-Log ("Pagina carregada ({0} bytes). Procurando formulario..." -f $html.Length) 'INFO'

        $forms = Get-Formularios -Html $html -BaseUrl $baseUrl
        if ($forms.Count -gt 0) {
            $f = $forms[0]
            Write-Log ("Formulario: {0} {1} ({2} campos)" -f $f.Method, $f.ActionAbs, $f.Inputs.Count) 'INFO'
            $body = ($f.Inputs.GetEnumerator() | ForEach-Object { "{0}={1}" -f [Uri]::EscapeDataString($_.Key), [Uri]::EscapeDataString([string]$_.Value) }) -join '&'
            if ($f.Method -eq 'POST') {
                $r = Invoke-WebRequest -Uri $f.ActionAbs -Method POST -Body $body -ContentType 'application/x-www-form-urlencoded' -UseBasicParsing -TimeoutSec 15 -MaximumRedirection 5
            } else {
                $sep = '?'; if ($f.ActionAbs -match '\?') { $sep = '&' }
                $r = Invoke-WebRequest -Uri ($f.ActionAbs + $sep + $body) -UseBasicParsing -TimeoutSec 15 -MaximumRedirection 5
            }
            Write-Log ("Formulario enviado. HTTP {0}" -f [int]$r.StatusCode) 'OK'
            return $true
        }

        # --- Estrategia 3: meta-refresh / link ---
        if ($html -match '(?i)<meta[^>]*http-equiv=["'']?refresh["''][^>]*url=([^"''>\s]+)') {
            $dest = ConvertTo-UrlAbsoluta -Base $baseUrl -Ref $Matches[1]
            Write-Log ("Seguindo meta-refresh para: {0}" -f $dest) 'INFO'
            $r = Invoke-WebRequest -Uri $dest -UseBasicParsing -TimeoutSec 15 -MaximumRedirection 5
            Write-Log ("HTTP {0}" -f [int]$r.StatusCode) 'OK'
            return $true
        }

        Write-Log 'Nao achei formulario nem redirect simples nesta pagina.' 'AVISO'
        Write-Log 'O "Proximo" provavelmente usa JavaScript. Rode -Capturar e me envie o arquivo.' 'AVISO'
        return $false
    } catch {
        Write-LogErro $_ "Falha ao processar a pagina do portal ($PortalUrl)"
        return $false
    }
}

function Capturar-Portal {
    # Baixa TUDO da pagina do portal para um arquivo que voce me envia.
    param($Cfg)
    Write-Log 'Modo CAPTURA. Verificando estado da rede...' 'PASSO'
    $est = Testar-Conexao -Cfg $Cfg
    Write-Log ("Estado: {0}  PortalUrl: {1}" -f $est.Estado, $est.PortalUrl) 'INFO'
    if ($est.Estado -eq 'ONLINE') {
        Write-Log 'A internet esta ONLINE agora - nao ha portal para capturar.' 'AVISO'
        Write-Log 'Rode este -Capturar QUANDO a conexao estiver caida (tela "Bem-vindo de volta").' 'AVISO'
        return
    }
    $url = $est.PortalUrl
    if (-not $url) { $url = Read-Host 'Nao detectei a URL. Cole a URL que aparece no navegador do portal' }
    $arq = Join-Path $script:PastaLog ("captura-portal-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("CAPTURA DO PORTAL - $(Get-Date)")
    [void]$sb.AppendLine("URL: $url")
    [void]$sb.AppendLine(('=' * 70))
    try {
        $pg = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 20 -MaximumRedirection 5
        $baseUrl = $url; try { if ($pg.BaseResponse.ResponseUri) { $baseUrl = $pg.BaseResponse.ResponseUri.AbsoluteUri } } catch {}
        [void]$sb.AppendLine("URL FINAL: $baseUrl")
        [void]$sb.AppendLine("HTTP: $([int]$pg.StatusCode)")
        [void]$sb.AppendLine(''); [void]$sb.AppendLine('----- FORMULARIOS -----')
        $forms = Get-Formularios -Html $pg.Content -BaseUrl $baseUrl
        if ($forms.Count -eq 0) { [void]$sb.AppendLine('(nenhum formulario <form> encontrado)') }
        foreach ($f in $forms) {
            [void]$sb.AppendLine(("FORM {0} -> {1}" -f $f.Method, $f.ActionAbs))
            foreach ($k in $f.Inputs.Keys) { [void]$sb.AppendLine(("   input {0} = {1}" -f $k, $f.Inputs[$k])) }
        }
        [void]$sb.AppendLine(''); [void]$sb.AppendLine('----- SCRIPTS (src) -----')
        foreach ($m in [regex]::Matches($pg.Content, '(?i)<script[^>]*src\s*=\s*["'']([^"'']+)["'']')) { [void]$sb.AppendLine($m.Groups[1].Value) }
        [void]$sb.AppendLine(''); [void]$sb.AppendLine('----- LINKS/BOTOES com "proximo/next" -----')
        foreach ($m in [regex]::Matches($pg.Content, '(?is)<(a|button)\b[^>]*>.*?</\1>')) {
            if ($m.Value -match '(?i)pr.?ximo|next') { [void]$sb.AppendLine(($m.Value -replace '\s+', ' ')) }
        }
        [void]$sb.AppendLine(''); [void]$sb.AppendLine('----- HTML COMPLETO -----')
        [void]$sb.AppendLine($pg.Content)
    } catch {
        [void]$sb.AppendLine("ERRO ao baixar: $($_.Exception.Message)")
        Write-LogErro $_ 'Falha na captura'
    }
    Set-Content -Path $arq -Value $sb.ToString() -Encoding UTF8
    Write-Log ("Captura salva em: {0}" -f $arq) 'OK'
    Write-Host ''
    Write-Host '  >>> ME ENVIE o conteudo desse arquivo (abra, Ctrl+A, Ctrl+C) <<<' -ForegroundColor Green
    Write-Host '  Com ele eu monto o login exato (LoginReplay) e fica 100% automatico.' -ForegroundColor Green
}

function Mostrar-Logs {
    param([int] $N)
    if (-not (Test-Path $script:ArqLog)) { Write-Host 'Ainda nao ha log hoje.'; return }
    Write-Host ("Arquivo de log: {0}" -f $script:ArqLog) -ForegroundColor Cyan
    Write-Host ('-' * 70)
    Get-Content $script:ArqLog -Tail $N
}

# ------------------------------------------------------------------ Loop principal
function Iniciar-Monitor {
    param($Cfg)

    if (-not $Cfg.SSID) {
        Write-Log 'Rodando em MODO PORTAL (sem gerenciar Wi-Fi). Para escolher um Wi-Fi depois: -Configurar' 'INFO'
    }

    $alvo = if ($Cfg.SSID) { "'$($Cfg.SSID)'" } else { '(modo portal - sem gerenciar Wi-Fi)' }
    Write-Log '====================================================================' 'PASSO'
    Write-Log ("MONITOR INICIADO  |  Wi-Fi alvo: {0}  |  Intervalo: {1}s" -f $alvo, $Cfg.IntervaloSegundos) 'PASSO'
    Write-Log ("Config: {0}" -f $script:ArqConfig) 'INFO'
    Write-Log ("Log   : {0}" -f $script:ArqLog) 'INFO'
    Write-Log 'Para parar: feche a janela ou pressione Ctrl+C.' 'INFO'
    Write-Log '====================================================================' 'PASSO'

    $ciclos = 0; $quedas = 0; $recuperacoes = 0
    while ($true) {
        $ciclos++
        try {
            # Checa se o Wi-Fi alvo esta no alcance; se nao, oferece novo menu (1x).
            $atual = Get-WifiAtual
            $est = Testar-Conexao -Cfg $Cfg

            if ($est.Estado -eq 'ONLINE') {
                Write-Log ("[ciclo {0}] ONLINE  (Wi-Fi: '{1}')" -f $ciclos, $atual) 'OK'
            }
            elseif ($est.Estado -eq 'CATIVO') {
                $quedas++
                Write-Log ("[ciclo {0}] PORTAL CATIVO detectado (queda #{1}). Recuperando..." -f $ciclos, $quedas) 'AVISO'

                if (-not $SemReconectar -and $Cfg.ReconectarWifi) {
                    if ($atual -ne $Cfg.SSID) {
                        $visiveis = Get-RedesVisiveis
                        if ($visiveis -notcontains $Cfg.SSID) {
                            Write-Log ("O Wi-Fi '{0}' NAO esta no alcance. Redes visiveis: {1}" -f $Cfg.SSID, ($visiveis -join ', ')) 'AVISO'
                            $Cfg = Selecionar-Wifi -Cfg $Cfg
                        }
                        Conectar-Wifi -SSID $Cfg.SSID | Out-Null
                        Start-Sleep -Seconds 3
                        $est = Testar-Conexao -Cfg $Cfg
                    }
                }

                if ($est.Estado -ne 'ONLINE') {
                    $ok = Invoke-Login -Cfg $Cfg -PortalUrl $est.PortalUrl
                    Start-Sleep -Seconds 4
                    $pos = Testar-Conexao -Cfg $Cfg
                    if ($pos.Estado -eq 'ONLINE') {
                        $recuperacoes++
                        Write-Log ("RECUPERADO! Internet voltou (recuperacao #{0})." -f $recuperacoes) 'OK'
                    } else {
                        Write-Log ("Ainda nao voltou (estado: {0}). Vou tentar de novo no proximo ciclo." -f $pos.Estado) 'AVISO'
                    }
                }
            }
            else {
                Write-Log ("[ciclo {0}] OFFLINE (sem rede fisica/radio). Aguardando a placa voltar..." -f $ciclos) 'AVISO'
                if (-not $SemReconectar -and $Cfg.ReconectarWifi) { Conectar-Wifi -SSID $Cfg.SSID | Out-Null }
            }
        } catch {
            Write-LogErro $_ "Erro inesperado no ciclo $ciclos"
        }

        Start-Sleep -Seconds $Cfg.IntervaloSegundos
    }
}

# ------------------------------------------------------------------ Dispatch
$cfg = Carregar-Config
if ($Intervalo -gt 0) { $cfg.IntervaloSegundos = $Intervalo }

Write-Log ("ReconectarWifi iniciado. Pasta: {0}" -f $script:Raiz) 'INFO'

if ($Logs -gt 0)      { Mostrar-Logs -N $Logs; return }
if ($Configurar)      { Selecionar-Wifi -Cfg $cfg | Out-Null; return }
if ($Capturar)        { Capturar-Portal -Cfg $cfg; return }
if ($Verificar) {
    $e = Testar-Conexao -Cfg $cfg
    Write-Log ("Resultado da verificacao: Estado={0}  PortalUrl={1}  Wi-Fi atual='{2}'" -f $e.Estado, $e.PortalUrl, (Get-WifiAtual)) 'INFO'
    return
}

Iniciar-Monitor -Cfg $cfg
