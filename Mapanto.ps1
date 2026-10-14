#Requires -Version 5.1
<#
================================================================================
  Mapanto.ps1  -  Supervisor unico (TUNEL + WI-FI/PORTAL + SAUDE + LOGS)
  --------------------------------------------------------------------------
  Faz tudo num arquivo so:
   1) Inicia e VIGIA o tunnelto (tunnelto.exe --subdomain mapanto --port 8080).
      - Se o tunel FECHA  -> reabre.
      - Se o tunel TRAVA (fica vivo mas para de responder em mapanto.tunn.dev)
        -> mata e reabre sozinho. (Esse era o problema do .bat antigo.)
   2) Mantem a sessao do portal cativo (ZooxWiFi) viva e, se cair, loga/captura
      e tenta o login automatico.
   3) Grava LOG COMPLETO de tudo para voce me enviar se der erro.

  COMANDOS (PowerShell na pasta deste arquivo):
     Rodar o supervisor:          .\Mapanto.ps1
     Instalar inicio automatico:  .\Mapanto.ps1 -Instalar      (abre sozinho no login)
     Remover inicio automatico:   .\Mapanto.ps1 -Desinstalar
     Status rapido (1 vez):       .\Mapanto.ps1 -Status
     Ver ultimas linhas do log:   .\Mapanto.ps1 -Logs 120
     Capturar portal (se caido):  .\Mapanto.ps1 -Capturar

  Se o Windows bloquear scripts (so nesta janela):
     Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

  IMPORTANTE: pare o "Clica aqui no tunel.bat" antigo antes de usar este
  (senao ficam dois tuneis brigando pelo mesmo subdominio).
================================================================================
#>

[CmdletBinding()]
param(
    [switch] $Instalar,
    [switch] $Desinstalar,
    [switch] $Status,
    [switch] $Capturar,
    [int]    $Logs = 0,
    [int]    $Intervalo = 0,
    [switch] $SemTunel,
    [switch] $SemPortal
)

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls } catch {}

$script:Raiz      = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$script:PastaLog  = Join-Path $script:Raiz 'Logs'
$script:ArqConfig = Join-Path $script:Raiz 'mapanto-config.json'
if (-not (Test-Path $script:PastaLog)) { New-Item -ItemType Directory -Path $script:PastaLog -Force | Out-Null }
$script:ArqLog    = Join-Path $script:PastaLog ("mapanto-{0}.log" -f (Get-Date -Format 'yyyy-MM-dd'))
$script:TunelProc = $null
$script:ProximaChecagemTunel = Get-Date
$script:UltimoInicioTunel = $null

# ============================================================ LOG
function Write-Log {
    param([string]$Msg, [ValidateSet('INFO','OK','AVISO','ERRO','DEBUG','PASSO','TUNEL')][string]$Nivel='INFO')
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $linha = "[{0}] [{1,-5}] {2}" -f $ts, $Nivel, $Msg
    try { Add-Content -Path $script:ArqLog -Value $linha -Encoding UTF8 } catch {}
    $cor = switch ($Nivel) { 'OK'{'Green'} 'AVISO'{'Yellow'} 'ERRO'{'Red'} 'DEBUG'{'DarkGray'} 'PASSO'{'Cyan'} 'TUNEL'{'Magenta'} default{'Gray'} }
    Write-Host $linha -ForegroundColor $cor
}
function Write-LogErro {
    param([System.Management.Automation.ErrorRecord]$Err, [string]$Contexto='')
    Write-Log '================= ERRO (copie deste bloco ate o fim) =================' 'ERRO'
    if ($Contexto) { Write-Log ("Contexto : {0}" -f $Contexto) 'ERRO' }
    Write-Log ("Mensagem : {0}" -f $Err.Exception.Message) 'ERRO'
    Write-Log ("Tipo     : {0}" -f $Err.Exception.GetType().FullName) 'ERRO'
    if ($Err.InvocationInfo) { Write-Log ("Local    : linha {0}: {1}" -f $Err.InvocationInfo.ScriptLineNumber, ($Err.InvocationInfo.Line).Trim()) 'ERRO' }
    Write-Log ("Pilha    : {0}" -f ($Err.ScriptStackTrace -replace "`r?`n",' | ')) 'ERRO'
    Write-Log '=====================================================================' 'ERRO'
}
function Mascarar([string]$s) { if (-not $s) { return '(vazio)' }; if ($s.Length -le 6) { return '****' }; return ($s.Substring(0,4) + '****') }

# ============================================================ CONFIG
function Get-ConfigPadrao {
    [pscustomobject]@{
        TunnelExe            = 'C:\tunnelto\tunnelto.exe'
        TunnelDir            = 'C:\tunnelto'
        TunnelBat            = ''
        Subdomain            = 'mapanto'
        PortaLocal           = 8080
        Key                  = ''
        UrlPublica           = 'https://mapanto.tunn.dev'
        IntervaloSegundos    = 30
        FalhasParaReiniciar  = 3
        GraceAposReinicioSeg = 25
        SondaUrl             = 'http://www.msftconnecttest.com/connecttest.txt'
        SondaTextoOk         = 'Microsoft Connect Test'
        SondaRedirectUrl     = 'http://www.msftconnecttest.com/redirect'
        GerenciarTunel       = $true
        GerenciarPortal      = $true
        LoginReplay          = $null
        UltimaAtualizacao    = (Get-Date).ToString('s')
    }
}
function Carregar-Config {
    if (Test-Path $script:ArqConfig) {
        try {
            $cfg = (Get-Content $script:ArqConfig -Raw -Encoding UTF8 | ConvertFrom-Json)
            $padrao = Get-ConfigPadrao
            foreach ($p in $padrao.PSObject.Properties) {
                if (-not ($cfg.PSObject.Properties.Name -contains $p.Name)) { $cfg | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force }
            }
            return $cfg
        } catch { Write-LogErro $_ 'Config corrompida - usando padrao'; return Get-ConfigPadrao }
    }
    return Get-ConfigPadrao
}
function Salvar-Config { param($Cfg); $Cfg.UltimaAtualizacao = (Get-Date).ToString('s'); $Cfg | ConvertTo-Json -Depth 8 | Set-Content -Path $script:ArqConfig -Encoding UTF8 }

function Resolver-Tunel {
    # Localiza o tunnelto.exe e, principalmente, o .bat que JA FUNCIONA (usado como lancador).
    param($Cfg)
    if (-not (Test-Path $Cfg.TunnelExe)) {
        $alt = Get-ChildItem 'C:\' -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'tunnelto' } | Select-Object -First 1
        $cand = @('C:\tunnelto\tunnelto.exe')
        if ($alt) { $cand += (Join-Path $alt.FullName 'tunnelto.exe') }
        foreach ($c in $cand) { if (Test-Path $c) { $Cfg.TunnelExe = $c; $Cfg.TunnelDir = (Split-Path $c -Parent); break } }
    }
    if (-not $Cfg.TunnelBat -or -not (Test-Path $Cfg.TunnelBat)) {
        foreach ($loc in @($Cfg.TunnelDir, 'C:\tunnelto', $script:Raiz)) {
            if ($loc -and (Test-Path $loc)) {
                foreach ($b in (Get-ChildItem $loc -Filter *.bat -ErrorAction SilentlyContinue)) {
                    $txt = Get-Content $b.FullName -Raw -ErrorAction SilentlyContinue
                    if ($txt -and $txt -match 'tunnelto\.exe') {
                        $Cfg.TunnelBat = $b.FullName
                        if ($txt -match '--subdomain\s+(\S+)') { $Cfg.Subdomain  = $Matches[1] }
                        if ($txt -match '--port\s+(\d+)')      { $Cfg.PortaLocal = [int]$Matches[1] }
                        if (-not $Cfg.Key -and $txt -match '--key\s+(\S+)') { $Cfg.Key = $Matches[1] }
                        Write-Log ("Lancador do tunel encontrado: {0}" -f $b.FullName) 'INFO'
                        Salvar-Config $Cfg
                        return $Cfg
                    }
                }
            }
        }
    }
    return $Cfg
}

# ============================================================ PORTAL (HTTP)
function Invoke-Probe {
    param([string]$Url, [int]$TimeoutSec=8)
    try {
        $r = Invoke-WebRequest -Uri $Url -MaximumRedirection 0 -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
        $loc=$null; try{$loc=$r.Headers.Location}catch{}
        return [pscustomobject]@{ Status=[int]$r.StatusCode; Location=$loc; Body=$r.Content }
    } catch {
        $resp=$null; try{$resp=$_.Exception.Response}catch{}
        if ($resp) {
            $status=0; try{$status=[int]$resp.StatusCode}catch{}
            $loc=$null; try{$loc=$resp.Headers['Location']}catch{}
            $body=$null; try{$sr=New-Object IO.StreamReader($resp.GetResponseStream());$body=$sr.ReadToEnd();$sr.Close()}catch{}
            return [pscustomobject]@{ Status=$status; Location=$loc; Body=$body }
        }
        return [pscustomobject]@{ Status=0; Location=$null; Body=$null }
    }
}
function Testar-Conexao {
    param($Cfg)
    try {
        $r = Invoke-WebRequest -Uri $Cfg.SondaUrl -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop
        if ($r.Content -and ($r.Content -match [regex]::Escape($Cfg.SondaTextoOk))) { return @{ Estado='ONLINE'; PortalUrl=$null } }
        $portal=$null; try { if ($r.BaseResponse.ResponseUri) { $portal=$r.BaseResponse.ResponseUri.AbsoluteUri } } catch {}
        if ($r.Content -and ($r.Content -match 'https?://[^"'' ]*zooxwifi[^"'' ]*')) { $portal=$Matches[0] }
        return @{ Estado='CATIVO'; PortalUrl=$portal }
    } catch {
        $p2 = Invoke-Probe -Url $Cfg.SondaRedirectUrl
        if ($p2.Status -ge 300 -and $p2.Status -lt 400 -and $p2.Location) { return @{ Estado='CATIVO'; PortalUrl=$p2.Location } }
        if ($p2.Body -and ($p2.Body -match 'https?://[^"'' ]*zooxwifi[^"'' ]*')) { return @{ Estado='CATIVO'; PortalUrl=$Matches[0] } }
        return @{ Estado='OFFLINE'; PortalUrl=$null }
    }
}
function ConvertTo-UrlAbsoluta { param([string]$Base,[string]$Ref); try { return ([Uri]::new([Uri]$Base,$Ref)).AbsoluteUri } catch { return $Ref } }
function Get-Formularios {
    param([string]$Html,[string]$BaseUrl)
    $forms=@()
    foreach ($mf in [regex]::Matches($Html,'(?is)<form\b([^>]*)>(.*?)</form>')) {
        $attrs=$mf.Groups[1].Value; $corpo=$mf.Groups[2].Value
        $action=''; if ($attrs -match '(?i)action\s*=\s*["'']?([^"''\s>]+)') { $action=$Matches[1] }
        $method='GET'; if ($attrs -match '(?i)method\s*=\s*["'']?(get|post)') { $method=$Matches[1].ToUpper() }
        $inputs=@{}
        foreach ($mi in [regex]::Matches($corpo,'(?is)<input\b([^>]*)>')) {
            $ia=$mi.Groups[1].Value
            $nome=''; if ($ia -match '(?i)name\s*=\s*["'']?([^"''\s>]+)') { $nome=$Matches[1] }
            $val='';  if ($ia -match '(?i)value\s*=\s*["'']([^"'']*)["'']') { $val=$Matches[1] } elseif ($ia -match '(?i)value\s*=\s*([^"''\s>]+)') { $val=$Matches[1] }
            if ($nome) { $inputs[$nome]=$val }
        }
        $forms += [pscustomobject]@{ ActionAbs=(ConvertTo-UrlAbsoluta -Base $BaseUrl -Ref $action); Method=$method; Inputs=$inputs }
    }
    return $forms
}
function Salvar-CapturaPortal {
    param([string]$Url)
    if (-not $Url) { return $null }
    $arq = Join-Path $script:PastaLog ("captura-portal-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("CAPTURA DO PORTAL - $(Get-Date)"); [void]$sb.AppendLine("URL: $Url"); [void]$sb.AppendLine(('='*70))
    try {
        $pg = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 20 -MaximumRedirection 5
        $baseUrl=$Url; try { if ($pg.BaseResponse.ResponseUri) { $baseUrl=$pg.BaseResponse.ResponseUri.AbsoluteUri } } catch {}
        [void]$sb.AppendLine("URL FINAL: $baseUrl"); [void]$sb.AppendLine("HTTP: $([int]$pg.StatusCode)")
        [void]$sb.AppendLine(''); [void]$sb.AppendLine('----- FORMULARIOS -----')
        $forms = Get-Formularios -Html $pg.Content -BaseUrl $baseUrl
        if ($forms.Count -eq 0) { [void]$sb.AppendLine('(nenhum formulario <form>)') }
        foreach ($f in $forms) { [void]$sb.AppendLine(("FORM {0} -> {1}" -f $f.Method,$f.ActionAbs)); foreach ($k in $f.Inputs.Keys) { [void]$sb.AppendLine(("   input {0} = {1}" -f $k,$f.Inputs[$k])) } }
        [void]$sb.AppendLine(''); [void]$sb.AppendLine('----- SCRIPTS -----')
        foreach ($m in [regex]::Matches($pg.Content,'(?i)<script[^>]*src\s*=\s*["'']([^"'']+)["'']')) { [void]$sb.AppendLine($m.Groups[1].Value) }
        [void]$sb.AppendLine(''); [void]$sb.AppendLine('----- BOTOES proximo/next -----')
        foreach ($m in [regex]::Matches($pg.Content,'(?is)<(a|button)\b[^>]*>.*?</\1>')) { if ($m.Value -match '(?i)pr.?ximo|next') { [void]$sb.AppendLine(($m.Value -replace '\s+',' ')) } }
        [void]$sb.AppendLine(''); [void]$sb.AppendLine('----- HTML COMPLETO -----'); [void]$sb.AppendLine($pg.Content)
    } catch { [void]$sb.AppendLine("ERRO ao baixar: $($_.Exception.Message)") }
    Set-Content -Path $arq -Value $sb.ToString() -Encoding UTF8
    return $arq
}
function Invoke-Login {
    param($Cfg,[string]$PortalUrl)
    if ($Cfg.LoginReplay) {
        try {
            $lr=$Cfg.LoginReplay; $hdr=@{}; if ($lr.Headers) { $lr.Headers.PSObject.Properties | ForEach-Object { $hdr[$_.Name]=$_.Value } }
            $a=@{ Uri=$lr.Url; Method=$lr.Method; UseBasicParsing=$true; TimeoutSec=15; Headers=$hdr }
            if ($lr.Body) { $a.Body=$lr.Body }; if ($lr.ContentType) { $a.ContentType=$lr.ContentType }
            $r=Invoke-WebRequest @a; Write-Log ("Login (replay) HTTP {0}" -f [int]$r.StatusCode) 'OK'; return $true
        } catch { Write-LogErro $_ 'Falha no login via replay' }
    }
    if (-not $PortalUrl) { Write-Log 'Sem URL do portal e sem replay. Rode -Capturar e me envie.' 'AVISO'; return $false }
    try {
        $pg = Invoke-WebRequest -Uri $PortalUrl -UseBasicParsing -TimeoutSec 15 -MaximumRedirection 5
        $baseUrl=$PortalUrl; try { if ($pg.BaseResponse.ResponseUri) { $baseUrl=$pg.BaseResponse.ResponseUri.AbsoluteUri } } catch {}
        $forms = Get-Formularios -Html $pg.Content -BaseUrl $baseUrl
        if ($forms.Count -gt 0) {
            $f=$forms[0]
            $body = ($f.Inputs.GetEnumerator() | ForEach-Object { "{0}={1}" -f [Uri]::EscapeDataString($_.Key),[Uri]::EscapeDataString([string]$_.Value) }) -join '&'
            if ($f.Method -eq 'POST') { $r=Invoke-WebRequest -Uri $f.ActionAbs -Method POST -Body $body -ContentType 'application/x-www-form-urlencoded' -UseBasicParsing -TimeoutSec 15 -MaximumRedirection 5 }
            else { $sep='?'; if ($f.ActionAbs -match '\?') { $sep='&' }; $r=Invoke-WebRequest -Uri ($f.ActionAbs+$sep+$body) -UseBasicParsing -TimeoutSec 15 -MaximumRedirection 5 }
            Write-Log ("Formulario do portal enviado. HTTP {0}" -f [int]$r.StatusCode) 'OK'; return $true
        }
        if ($pg.Content -match '(?i)<meta[^>]*http-equiv=["'']?refresh["''][^>]*url=([^"''>\s]+)') {
            $dest=ConvertTo-UrlAbsoluta -Base $baseUrl -Ref $Matches[1]; $r=Invoke-WebRequest -Uri $dest -UseBasicParsing -TimeoutSec 15 -MaximumRedirection 5
            Write-Log ("Portal: segui meta-refresh. HTTP {0}" -f [int]$r.StatusCode) 'OK'; return $true
        }
        Write-Log 'Portal sem formulario simples (provavelmente JavaScript). Rode -Capturar e me envie.' 'AVISO'; return $false
    } catch { Write-LogErro $_ "Falha ao processar portal ($PortalUrl)"; return $false }
}

# ============================================================ TUNEL
function Test-PortaLocal {
    param([int]$Porta)
    try {
        $c = New-Object Net.Sockets.TcpClient
        $iar = $c.BeginConnect('127.0.0.1',$Porta,$null,$null)
        $ok = $iar.AsyncWaitHandle.WaitOne(2000)
        if ($ok -and $c.Connected) { $c.EndConnect($iar); $c.Close(); return $true }
        $c.Close(); return $false
    } catch { return $false }
}
function Test-TunelConectado {
    # Verificacao LOCAL e confiavel: o processo tunnelto tem conexao TCP de saida
    # estabelecida (= tunel ligado ao servidor)? Nao depende de acessar a URL de fora
    # (que falha por TLS/proxy no proprio PC). Retorna $true / $false / $null (indefinido).
    try {
        $procs = Get-Process -Name 'tunnelto' -ErrorAction SilentlyContinue
        if (-not $procs) { return $null }   # sem processo agora (a .bat pode estar entre tentativas)
        $ids = @($procs | ForEach-Object { $_.Id })
        $conns = Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
                 Where-Object { ($ids -contains $_.OwningProcess) -and ($_.RemoteAddress -notin @('127.0.0.1','::1','0.0.0.0')) }
        if ($conns) { return $true } else { return $false }
    } catch { return $null }   # Get-NetTCPConnection indisponivel -> indefinido
}
function Test-TunelPublico {
    param([string]$Url,[int]$TimeoutSec=10)
    try {
        $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec -MaximumRedirection 3 -ErrorAction Stop
        return @{ Ok=$true; Definitivo=$true; Detalhe=("HTTP {0}" -f [int]$r.StatusCode) }
    } catch {
        $resp=$null; try{$resp=$_.Exception.Response}catch{}
        if ($resp) {
            $sc=0; try{$sc=[int]$resp.StatusCode}catch{}
            if ($sc -in @(502,503,504,522,523,524)) { return @{ Ok=$false; Definitivo=$true; Detalhe=("HTTP {0} tunel sem resposta" -f $sc) } }
            return @{ Ok=$true; Definitivo=$true; Detalhe=("HTTP {0} (app respondeu)" -f $sc) }
        }
        # Sem resposta HTTP (TLS/proxy/timeout do proprio PC) = inconclusivo, NAO reinicia.
        return @{ Ok=$false; Definitivo=$false; Detalhe=("checagem externa indisponivel: {0}" -f $_.Exception.Message) }
    }
}
function Iniciar-Tunel {
    param($Cfg)
    try { Get-Process -Name 'tunnelto' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue } catch {}
    Start-Sleep -Milliseconds 500
    # PREFERE o .bat que ja funciona (console real, SEM redirect). Foi assim que o
    # tunel conecta de verdade; esconder/redirecionar a saida faz o servidor recusar.
    if ($Cfg.TunnelBat -and (Test-Path $Cfg.TunnelBat)) {
        try {
            $p = Start-Process -FilePath $Cfg.TunnelBat -WorkingDirectory (Split-Path $Cfg.TunnelBat -Parent) -WindowStyle Minimized -PassThru
            $script:TunelProc = $p
            $script:UltimoInicioTunel = Get-Date
            Write-Log ("Tunel iniciado via '{0}' (janela minimizada, PID {1})." -f (Split-Path $Cfg.TunnelBat -Leaf),$p.Id) 'TUNEL'
            return $p
        } catch { Write-LogErro $_ 'Falha ao iniciar o tunel pelo .bat' }
    }
    # Fallback: exe direto, console minimizado, SEM redirect (igual ao .bat).
    if (-not (Test-Path $Cfg.TunnelExe)) { Write-Log ("tunnelto.exe NAO encontrado em: {0}" -f $Cfg.TunnelExe) 'ERRO'; return $null }
    if (-not $Cfg.Key) { Write-Log 'Sem a chave (--key) nem .bat. Coloque a chave em mapanto-config.json ou mantenha o .bat na pasta.' 'ERRO'; return $null }
    $argumentos = @('--subdomain',$Cfg.Subdomain,'--port',[string]$Cfg.PortaLocal,'--key',$Cfg.Key)
    try {
        $p = Start-Process -FilePath $Cfg.TunnelExe -ArgumentList $argumentos -WorkingDirectory $Cfg.TunnelDir -WindowStyle Minimized -PassThru
        $script:TunelProc = $p
        $script:UltimoInicioTunel = Get-Date
        Write-Log ("Tunel iniciado (PID {0}): tunnelto.exe --subdomain {1} --port {2} --key {3}" -f $p.Id,$Cfg.Subdomain,$Cfg.PortaLocal,(Mascarar $Cfg.Key)) 'TUNEL'
        return $p
    } catch { Write-LogErro $_ 'Falha ao iniciar o tunel'; return $null }
}
function Parar-Tunel {
    # Mata a arvore inteira (cmd do .bat -> powershell -> tunnelto).
    try { if ($script:TunelProc -and -not $script:TunelProc.HasExited) { & taskkill.exe /F /T /PID $script:TunelProc.Id 2>$null | Out-Null } } catch {}
    try { Get-Process -Name 'tunnelto' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue } catch {}
}
function Reiniciar-Tunel {
    param($Cfg,[string]$Motivo)
    Write-Log ("REINICIANDO o tunel. Motivo: {0}" -f $Motivo) 'TUNEL'
    $err = Join-Path $script:PastaLog 'tunnel-erro.log'
    if (Test-Path $err) { $tail = Get-Content $err -Tail 8 -ErrorAction SilentlyContinue; if ($tail) { Write-Log ("Ultimas saidas do tunel: {0}" -f (($tail -join ' | ') -replace $Cfg.Key,'****')) 'INFO' } }
    Parar-Tunel
    Start-Sleep -Seconds 3
    Iniciar-Tunel -Cfg $Cfg | Out-Null
}

# ============================================================ UI / INSTALL
function Mostrar-Cabecalho {
    param($Cfg)
    $larg = 68
    Write-Host ''
    Write-Host ('  +' + ('-'*$larg) + '+') -ForegroundColor Cyan
    Write-Host ('  |' + ('  MAPANTO - Supervisor de Tunel + Wi-Fi'.PadRight($larg)) + '|') -ForegroundColor Cyan
    Write-Host ('  +' + ('-'*$larg) + '+') -ForegroundColor Cyan
    $lanc = if ($Cfg.TunnelBat) { ("  Lancador  : {0}" -f $Cfg.TunnelBat) } else { ("  Executavel: {0}  chave: {1}" -f $Cfg.TunnelExe,(Mascarar $Cfg.Key)) }
    $linhas = @(
        ("  Tunel     : {0} (porta {1})  ->  {2}" -f $Cfg.Subdomain,$Cfg.PortaLocal,$Cfg.UrlPublica),
        $lanc,
        ("  Intervalo : {0}s   Reinicia tunel apos {1} falhas seguidas" -f $Cfg.IntervaloSegundos,$Cfg.FalhasParaReiniciar),
        ("  Log       : {0}" -f $script:ArqLog)
    )
    foreach ($l in $linhas) { Write-Host $l -ForegroundColor DarkGray }
    Write-Host '  Para parar: feche a janela ou Ctrl+C.' -ForegroundColor DarkGray
    Write-Host ''
}
function Instalar-Inicio {
    $startup = [Environment]::GetFolderPath('Startup')
    $lnk = Join-Path $startup 'Mapanto - Tunel e Wifi.lnk'
    $script = Join-Path $script:Raiz 'Mapanto.ps1'
    try {
        $ws = New-Object -ComObject WScript.Shell
        $s = $ws.CreateShortcut($lnk)
        $s.TargetPath = (Join-Path $PSHOME 'powershell.exe')
        $s.Arguments  = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Minimized -File `"$script`""
        $s.WorkingDirectory = $script:Raiz
        $s.WindowStyle = 7
        $s.Description  = 'Mapanto: supervisor do tunel + wifi'
        $s.Save()
        Write-Log ("Inicio automatico criado: {0}" -f $lnk) 'OK'
        Write-Log 'Ele abrira sozinho no seu proximo login e roda com a tela bloqueada (nao precisa de admin).' 'INFO'
    } catch { Write-LogErro $_ 'Falha ao criar o atalho de inicio' }
}
function Desinstalar-Inicio {
    $lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Mapanto - Tunel e Wifi.lnk'
    if (Test-Path $lnk) { Remove-Item $lnk -Force; Write-Log 'Inicio automatico removido.' 'OK' } else { Write-Log 'Nao havia inicio automatico instalado.' 'INFO' }
}
function Mostrar-Logs { param([int]$N); if (-not (Test-Path $script:ArqLog)) { Write-Host 'Sem log hoje.'; return }; Write-Host ("Log: {0}" -f $script:ArqLog) -ForegroundColor Cyan; Write-Host ('-'*70); Get-Content $script:ArqLog -Tail $N }

function Status-Unico {
    param($Cfg)
    $est = Testar-Conexao -Cfg $Cfg
    $local = Test-PortaLocal -Porta $Cfg.PortaLocal
    $proc = Get-Process -Name 'tunnelto' -ErrorAction SilentlyContinue
    $conn = Test-TunelConectado
    $pub = Test-TunelPublico -Url $Cfg.UrlPublica
    Write-Log ("Internet   : {0}" -f $est.Estado) 'INFO'
    Write-Log ("Processo   : {0}" -f ($(if($proc){"tunnelto rodando (PID $(($proc | ForEach-Object { $_.Id }) -join ','))"}else{'NAO esta rodando'}))) 'INFO'
    Write-Log ("Tunel conex: {0}" -f ($(if($conn -eq $true){'CONECTADO (saida estabelecida)'}elseif($conn -eq $false){'SEM conexao de saida'}else{'indefinido'}))) 'INFO'
    Write-Log ("App local  : porta {0} -> {1}" -f $Cfg.PortaLocal,($(if($local){'OK'}else{'nao responde'}))) 'INFO'
    Write-Log ("Tunel publ.: {0} -> {1} ({2})" -f $Cfg.UrlPublica,($(if($pub.Ok){'OK'}else{'nao deu (normal do proprio PC)'})),$pub.Detalhe) 'INFO'
}

# ============================================================ LOOP PRINCIPAL
function Iniciar-Supervisor {
    param($Cfg)
    Mostrar-Cabecalho $Cfg
    Write-Log '==================== SUPERVISOR INICIADO ====================' 'PASSO'

    if ($Cfg.GerenciarTunel -and -not $SemTunel) {
        Iniciar-Tunel -Cfg $Cfg | Out-Null
        $script:ProximaChecagemTunel = (Get-Date).AddSeconds($Cfg.GraceAposReinicioSeg)
    }

    $ciclo=0; $falhasTunel=0; $reinicios=0; $quedasPortal=0; $estadoAnterior='INICIO'; $mortesRapidas=0
    while ($true) {
        $ciclo++
        try {
            # ---- 1) PORTAL ----
            $est = @{ Estado='(ignorado)'; PortalUrl=$null }
            if ($Cfg.GerenciarPortal -and -not $SemPortal) {
                $est = Testar-Conexao -Cfg $Cfg
                if ($est.Estado -eq 'CATIVO') {
                    $quedasPortal++
                    Write-Log ("[ciclo {0}] PORTAL CATIVO (queda #{1}). Recuperando..." -f $ciclo,$quedasPortal) 'AVISO'
                    if ($estadoAnterior -ne 'CATIVO' -and $est.PortalUrl) { $cap=Salvar-CapturaPortal -Url $est.PortalUrl; if ($cap) { Write-Log ("Captura automatica: {0}" -f $cap) 'INFO' } }
                    Invoke-Login -Cfg $Cfg -PortalUrl $est.PortalUrl | Out-Null
                    Start-Sleep -Seconds 3
                    $est = Testar-Conexao -Cfg $Cfg
                    if ($est.Estado -eq 'ONLINE') { Write-Log 'Portal recuperado: internet voltou.' 'OK' }
                }
                $estadoAnterior = $est.Estado
            }

            # ---- 2) TUNEL ----
            $tunelInfo = 'desligado'
            if ($Cfg.GerenciarTunel -and -not $SemTunel) {
                $vivo = ($script:TunelProc -and -not $script:TunelProc.HasExited)
                if (-not $vivo) {
                    $viveu = if ($script:UltimoInicioTunel) { ((Get-Date) - $script:UltimoInicioTunel).TotalSeconds } else { 999 }
                    # Le o motivo que o proprio tunnelto deixou na saida de erro.
                    $motivo = ''
                    $errf = Join-Path $script:PastaLog 'tunnel-erro.log'
                    if ((Test-Path $errf) -and $script:UltimoInicioTunel -and ((Get-Item $errf).LastWriteTime -gt $script:UltimoInicioTunel)) {
                        try { $esc = if ($Cfg.Key) { [regex]::Escape($Cfg.Key) } else { '\x00nao\x00' }; $motivo = (((Get-Content $errf -Tail 6 -ErrorAction SilentlyContinue) -join ' | ') -replace $esc,'****').Trim() } catch {}
                    }
                    $chaveRecusada = ($motivo -match '(?i)access key|denied|unauthor|forbidden|invalid')
                    if ($motivo) { Write-Log ("Saida do tunel: {0}" -f $motivo) 'INFO' }
                    if ($viveu -lt 20) { $mortesRapidas++ } else { $mortesRapidas = 0 }

                    if ($chaveRecusada) {
                        Write-Log '===============================================================' 'ERRO'
                        Write-Log 'O SERVIDOR DO TUNNELTO RECUSOU A SUA CHAVE.' 'ERRO'
                        Write-Log 'Quase sempre e porque a MESMA chave ja esta ligada em OUTRO lugar' 'ERRO'
                        Write-Log '(a chave do tunnelto permite 1 tunel por vez).' 'ERRO'
                        Write-Log '  -> Feche o tunel/.bat antigo no SEU PC principal e rode o Mapanto' 'ERRO'
                        Write-Log '     em UMA so maquina (a que tem as impressoras e o site na porta 8080).' 'ERRO'
                        Write-Log '  -> Se nao for isso, confira a chave em https://dashboard.tunnelto.dev' 'ERRO'
                        Write-Log 'Esperando 60s antes de tentar de novo (evita loop).' 'ERRO'
                        Write-Log '===============================================================' 'ERRO'
                        Start-Sleep -Seconds 60
                        $mortesRapidas = 0
                    }
                    elseif ($mortesRapidas -ge 3) {
                        Write-Log '---------------------------------------------------------------' 'ERRO'
                        Write-Log 'O TUNEL ESTA ABRINDO E FECHANDO EM SEGUNDOS, repetidamente.' 'ERRO'
                        Write-Log ("Ultima saida do tunel: {0}" -f $(if($motivo){$motivo}else{'(vazia)'})) 'ERRO'
                        Write-Log 'Causas provaveis: chave em uso/invalida, subdominio ocupado, ou sem internet.' 'ERRO'
                        Write-Log 'Esperando 60s antes de tentar de novo (evita loop).' 'ERRO'
                        Write-Log '---------------------------------------------------------------' 'ERRO'
                        Start-Sleep -Seconds 60
                        $mortesRapidas = 0
                    }
                    Write-Log ("[ciclo {0}] Processo do tunel caiu (viveu {1:n0}s). Reabrindo..." -f $ciclo,$viveu) 'TUNEL'
                    Iniciar-Tunel -Cfg $Cfg | Out-Null
                    $script:ProximaChecagemTunel = (Get-Date).AddSeconds($Cfg.GraceAposReinicioSeg)
                    $falhasTunel=0; $tunelInfo='reaberto (tinha caido)'
                }
                elseif ((Get-Date) -lt $script:ProximaChecagemTunel) {
                    $tunelInfo = ("OK (PID {0}, aquecendo)" -f $script:TunelProc.Id)
                }
                elseif ($Cfg.GerenciarPortal -and $est.Estado -ne 'ONLINE' -and -not $SemPortal) {
                    $tunelInfo = ("aguardando internet ({0})" -f $est.Estado)
                }
                else {
                    $conectado = Test-TunelConectado
                    if ($conectado -eq $true) {
                        $falhasTunel = 0; $tunelInfo = 'OK (tunel conectado)'
                    }
                    elseif ($conectado -eq $false) {
                        # Processo vivo, mas SEM conexao de saida = provavel travamento real.
                        $falhasTunel++
                        Write-Log ("[ciclo {0}] tunnelto vivo mas SEM conexao de saida [{1}/{2}] (possivel travamento)." -f $ciclo,$falhasTunel,$Cfg.FalhasParaReiniciar) 'AVISO'
                        if ($falhasTunel -ge $Cfg.FalhasParaReiniciar) {
                            $reinicios++
                            Reiniciar-Tunel -Cfg $Cfg -Motivo ("tunel sem conexao de saida (reinicio #{0})" -f $reinicios)
                            $script:ProximaChecagemTunel = (Get-Date).AddSeconds($Cfg.GraceAposReinicioSeg)
                            $falhasTunel = 0; $tunelInfo = 'REABERTO (estava travado)'
                        } else { $tunelInfo = 'instavel (sem conexao de saida)' }
                    }
                    else {
                        # $null: nao deu pra checar pelo processo. Usa a checagem externa,
                        # mas so reinicia se for um erro DEFINITIVO (502/503/504), nunca por TLS/proxy.
                        $pub = Test-TunelPublico -Url $Cfg.UrlPublica
                        if ($pub.Ok) { $falhasTunel = 0; $tunelInfo = ("OK ({0})" -f $pub.Detalhe) }
                        elseif ($pub.Definitivo) {
                            $local = Test-PortaLocal -Porta $Cfg.PortaLocal
                            if (-not $local) {
                                $falhasTunel = 0; $tunelInfo = 'app local 8080 nao responde'
                                Write-Log ("[ciclo {0}] App local na porta {1} nao responde (nao e o tunel)." -f $ciclo,$Cfg.PortaLocal) 'AVISO'
                            } else {
                                $falhasTunel++
                                Write-Log ("[ciclo {0}] Tunel sem resposta ({1}) [{2}/{3}]." -f $ciclo,$pub.Detalhe,$falhasTunel,$Cfg.FalhasParaReiniciar) 'AVISO'
                                if ($falhasTunel -ge $Cfg.FalhasParaReiniciar) {
                                    $reinicios++
                                    Reiniciar-Tunel -Cfg $Cfg -Motivo ("tunel travado - {0} (reinicio #{1})" -f $pub.Detalhe,$reinicios)
                                    $script:ProximaChecagemTunel = (Get-Date).AddSeconds($Cfg.GraceAposReinicioSeg)
                                    $falhasTunel = 0; $tunelInfo = 'REABERTO (estava travado)'
                                } else { $tunelInfo = ("instavel ({0})" -f $pub.Detalhe) }
                            }
                        }
                        else { $falhasTunel = 0; $tunelInfo = 'OK (checagem externa indisponivel deste PC)' }
                    }
                }
            }

            # ---- 3) STATUS ----
            $nivel='OK'
            if ($tunelInfo -match 'reaberto|REABERTO|travad|instavel|NAO responde|aguardando' -or $est.Estado -eq 'OFFLINE') { $nivel='AVISO' }
            Write-Log ("[ciclo {0}] internet: {1} | tunel: {2}" -f $ciclo,$est.Estado,$tunelInfo) $nivel
        } catch { Write-LogErro $_ "Erro inesperado no ciclo $ciclo" }
        Start-Sleep -Seconds $Cfg.IntervaloSegundos
    }
}

# ============================================================ DISPATCH
$cfg = Carregar-Config
$cfg = Resolver-Tunel -Cfg $cfg
if ($Intervalo -gt 0) { $cfg.IntervaloSegundos = $Intervalo }

if ($Logs -gt 0)   { Mostrar-Logs -N $Logs; return }
if ($Instalar)     { Instalar-Inicio; return }
if ($Desinstalar)  { Desinstalar-Inicio; return }
if ($Status)       { Status-Unico -Cfg $cfg; return }
if ($Capturar) {
    $e = Testar-Conexao -Cfg $cfg
    if ($e.Estado -eq 'ONLINE') { Write-Log 'Internet ONLINE agora - nao ha portal caido para capturar.' 'AVISO'; return }
    $url = $e.PortalUrl; if (-not $url) { $url = Read-Host 'Cole a URL do portal' }
    $arq = Salvar-CapturaPortal -Url $url
    if ($arq) { Write-Log ("Captura salva em: {0}" -f $arq) 'OK'; try { notepad $arq } catch {} }
    return
}

# modo supervisor (unica instancia)
$script:Mutex = New-Object System.Threading.Mutex($false,'Local\MapantoSupervisor')
if (-not $script:Mutex.WaitOne(0)) { Write-Host 'Ja existe um Mapanto rodando nesta maquina. Feche o outro antes.' -ForegroundColor Yellow; return }
try { Iniciar-Supervisor -Cfg $cfg } finally { try { Parar-Tunel } catch {}; try { $script:Mutex.ReleaseMutex() } catch {} }
