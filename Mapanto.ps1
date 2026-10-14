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
        SondasAlternativas   = @([pscustomobject]@{ Url='https://www.gstatic.com/generate_204'; Status=204; Texto='' })
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
    # Configuracoes antigas podiam salvar outro subdominio mantendo a URL padrao.
    if (-not $Cfg.UrlPublica -or ($Cfg.UrlPublica -eq 'https://mapanto.tunn.dev' -and $Cfg.Subdomain -ne 'mapanto')) {
        $Cfg.UrlPublica = "https://$($Cfg.Subdomain).tunn.dev"
    }
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
                        $subAnterior = $Cfg.Subdomain
                        if ($txt -match '--subdomain\s+(\S+)') { $Cfg.Subdomain  = $Matches[1] }
                        if (-not $Cfg.UrlPublica -or $Cfg.UrlPublica -eq "https://$subAnterior.tunn.dev") {
                            $Cfg.UrlPublica = "https://$($Cfg.Subdomain).tunn.dev"
                        }
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
    param([string]$Url, [int]$TimeoutSec=8, [switch]$SeguirRedirecionamentos)
    $resultado = [pscustomobject]@{ Status=0; Location=$null; Body=$null; UrlFinal=$Url; Headers=$null; ContentHeaders=$null; Erro=$null }
    try {
        # Sondas nao seguem redirects; a checagem publica pode seguir ate tres.
        $maxRedirect = if ($SeguirRedirecionamentos) { 3 } else { 0 }
        $errosRequest = @()
        $request = @{ Uri=$Url; MaximumRedirection=$maxRedirect; UseBasicParsing=$true; TimeoutSec=$TimeoutSec; Headers=@{'Cache-Control'='no-cache'; Pragma='no-cache'}; ErrorAction='SilentlyContinue'; ErrorVariable='errosRequest' }
        # PS 7 pode descartar o corpo antes de lancar HttpResponseException.
        # PS 5.1 emite um erro nao terminante COM a resposta ao usar maxredirect=0.
        # Capturar esse erro preserva a resposta 302 em ambas as versoes.
        if ((Get-Command Invoke-WebRequest -ErrorAction Stop).Parameters.ContainsKey('SkipHttpErrorCheck')) { $request.SkipHttpErrorCheck = $true }
        $r = Invoke-WebRequest @request
        if (-not $r) {
            if ($errosRequest.Count) { throw $errosRequest[0] }
            throw 'A sonda nao recebeu uma resposta HTTP.'
        }
        $resultado.Status = [int]$r.StatusCode
        $resultado.Headers = $r.Headers
        $resultado.Body = if ($r.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($r.Content) } else { [string]$r.Content }
        try { $resultado.Location = [string](@($r.Headers['Location'])[0]) } catch {}
        try { if ($r.BaseResponse.ResponseUri) { $resultado.UrlFinal = $r.BaseResponse.ResponseUri.AbsoluteUri } } catch {}
        try { if ($r.BaseResponse.RequestMessage.RequestUri) { $resultado.UrlFinal = $r.BaseResponse.RequestMessage.RequestUri.AbsoluteUri } } catch {}
    } catch {
        $resp=$null; try{$resp=$_.Exception.Response}catch{}
        if ($resp) {
            try { $resultado.Status = [int]$resp.StatusCode } catch {}
            $resultado.Headers = $resp.Headers
            try { $resultado.Location = [string]$resp.Headers.Location } catch {}
            if (-not $resultado.Location) { try { $resultado.Location = [string]$resp.Headers['Location'] } catch {} }
            try { if ($resp.ResponseUri) { $resultado.UrlFinal = $resp.ResponseUri.AbsoluteUri } } catch {}
            try { if ($resp.RequestMessage.RequestUri) { $resultado.UrlFinal = $resp.RequestMessage.RequestUri.AbsoluteUri } } catch {}
            # Windows PowerShell 5.1 usa WebResponse; PowerShell 7 usa HttpResponseMessage.
            if ($resp.PSObject.Methods.Name -contains 'GetResponseStream') {
                $sr = $null
                try { $sr = New-Object IO.StreamReader($resp.GetResponseStream()); $resultado.Body = $sr.ReadToEnd() } catch {}
                finally { if ($sr) { $sr.Dispose() } }
            } else {
                try { $resultado.ContentHeaders = $resp.Content.Headers; $resultado.Body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult() } catch {}
            }
        } else {
            $resultado.Erro = $_.Exception.Message
        }
    }
    return $resultado
}
function Get-ProbePortal {
    param($Probe, [string]$Url, [string]$PortalHost='zooxwifi.com')
    $origem = $null; try { $origem = [Uri]$Url } catch {}
    $destino = $null
    if ($Probe.Location) { try { $destino = [Uri]::new([Uri]$Url, [string]$Probe.Location) } catch {} }
    $final = $null; try { $final = [Uri]$Probe.UrlFinal } catch {}
    foreach ($candidato in @($destino, $final)) {
        if ($candidato -and ($candidato.Host -eq $PortalHost -or $candidato.Host.EndsWith('.'+$PortalHost, [StringComparison]::OrdinalIgnoreCase))) {
            return [pscustomobject]@{ Url=$candidato.AbsoluteUri; Motivo='endereco do portal' }
        }
    }
    $body = [string]$Probe.Body
    foreach ($m in [regex]::Matches($body, 'https?://[^\s"''<>]*zooxwifi[^\s"''<>]*', [Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
        $candidato = $null; try { $candidato = [Uri][Net.WebUtility]::HtmlDecode($m.Value) } catch {}
        if ($candidato -and ($candidato.Host -eq $PortalHost -or $candidato.Host.EndsWith('.'+$PortalHost, [StringComparison]::OrdinalIgnoreCase))) {
            return [pscustomobject]@{ Url=$candidato.AbsoluteUri; Motivo='portal informado na resposta' }
        }
    }
    if ($Probe.Status -eq 511) {
        return [pscustomobject]@{ Url=$(if($destino){$destino.AbsoluteUri}else{$null}); Motivo='HTTP 511 exige autenticacao' }
    }
    if ($Probe.Status -ge 300 -and $Probe.Status -lt 400 -and $destino -and $origem -and $destino.Host -ne $origem.Host) {
        # /redirect normalmente leva ao Bing/MSN; isso nao e um portal cativo.
        $microsoft = $false
        foreach ($dominio in @('microsoft.com','msftconnecttest.com','msftncsi.com','bing.com','msn.com','live.com')) {
            if ($destino.Host -eq $dominio -or $destino.Host.EndsWith('.'+$dominio, [StringComparison]::OrdinalIgnoreCase)) { $microsoft = $true; break }
        }
        if (-not $microsoft -and $destino.Scheme -in @('http','https')) {
            return [pscustomobject]@{ Url=$destino.AbsoluteUri; Motivo='sonda redirecionada para autenticacao' }
        }
    }
    $formLogin = $body -match '(?is)<form\b[^>]*>.*?<input\b[^>]*type\s*=\s*["'']?password\b'
    $formPortal = ($body -match '(?is)<form\b[^>]*(?:login|signin|sign-in|auth)[^>]*>') -and ($body -match '(?i)captive\s+portal|portal\s+cativo|wi[\s-]?fi|acesso\s+[a\u00e0]\s+internet')
    if ($formLogin -or $formPortal) {
        $pagina = if ($final) { $final.AbsoluteUri } else { $Url }
        return [pscustomobject]@{ Url=$pagina; Motivo='formulario de autenticacao interceptou a sonda' }
    }
    return $null
}
function Testar-Conexao {
    param($Cfg)
    $sondas = @([pscustomobject]@{ Url=$Cfg.SondaUrl; Status=200; Texto=$Cfg.SondaTextoOk })
    if ($Cfg.SondasAlternativas) { $sondas += @($Cfg.SondasAlternativas) }
    $detalhes = @(); $portal = $null; $houveResposta = $false
    $portalHost = if ($Cfg.PortalHostContem) { [string]$Cfg.PortalHostContem } else { 'zooxwifi.com' }
    foreach ($sonda in $sondas) {
        if (-not $sonda.Url) { continue }
        $r = Invoke-Probe -Url $sonda.Url
        $houveResposta = $houveResposta -or ($r.Status -gt 0)
        $mesmoHost = $false
        try { $mesmoHost = ([Uri]$r.UrlFinal).Host -eq ([Uri]$sonda.Url).Host } catch {}
        $textoEsperado = [string]$sonda.Texto
        if ($r.Status -eq [int]$sonda.Status -and $mesmoHost -and ([string]$r.Body).Trim() -ceq $textoEsperado.Trim()) {
            return @{ Estado='ONLINE'; PortalUrl=$null; Detalhe=("Sonda confirmada: {0} (HTTP {1})" -f $sonda.Url,$r.Status) }
        }
        $detalhes += if ($r.Status -gt 0) { "Sonda $($sonda.Url): HTTP $($r.Status), resposta inesperada" } else { "Sonda $($sonda.Url): $($r.Erro)" }
        if (-not $portal) { $portal = Get-ProbePortal -Probe $r -Url $sonda.Url -PortalHost $portalHost }
    }
    # Uma falha isolada da Microsoft nao autoriza login/reconexao. Primeiro tenta
    # as alternativas; so considera CATIVO quando ha evidencia de autenticacao.
    if (-not $portal -and $Cfg.SondaRedirectUrl) {
        $r = Invoke-Probe -Url $Cfg.SondaRedirectUrl
        $houveResposta = $houveResposta -or ($r.Status -gt 0)
        $portal = Get-ProbePortal -Probe $r -Url $Cfg.SondaRedirectUrl -PortalHost $portalHost
        $detalhes += "Sonda de redirect: HTTP $($r.Status)"
    }
    if ($portal) { return @{ Estado='CATIVO'; PortalUrl=$portal.Url; Detalhe=$portal.Motivo } }
    $estado = if ($houveResposta) { 'INDEFINIDO' } else { 'OFFLINE' }
    return @{ Estado=$estado; PortalUrl=$null; Detalhe=($detalhes -join '; ') }
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
            $r=Invoke-WebRequest @a; Write-Log ("Login (replay) enviado: HTTP {0}. Confirmando conectividade..." -f [int]$r.StatusCode) 'INFO'; return $true
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
            Write-Log ("Formulario do portal enviado: HTTP {0}. Confirmando conectividade..." -f [int]$r.StatusCode) 'INFO'; return $true
        }
        if ($pg.Content -match '(?i)<meta[^>]*http-equiv=["'']?refresh["''][^>]*url=([^"''>\s]+)') {
            $dest=ConvertTo-UrlAbsoluta -Base $baseUrl -Ref $Matches[1]; $r=Invoke-WebRequest -Uri $dest -UseBasicParsing -TimeoutSec 15 -MaximumRedirection 5
            Write-Log ("Portal: segui meta-refresh: HTTP {0}. Confirmando conectividade..." -f [int]$r.StatusCode) 'INFO'; return $true
        }
        Write-Log 'Portal sem formulario simples (provavelmente JavaScript). Rode -Capturar e me envie.' 'AVISO'; return $false
    } catch { Write-LogErro $_ "Falha ao processar portal ($PortalUrl)"; return $false }
}

# ============================================================ TUNEL
function Test-PortaLocal {
    param([int]$Porta)
    $c = $null
    try {
        $c = New-Object Net.Sockets.TcpClient
        $iar = $c.BeginConnect('127.0.0.1',$Porta,$null,$null)
        $ok = $iar.AsyncWaitHandle.WaitOne(2000)
        if ($ok -and $c.Connected) { $c.EndConnect($iar); return $true }
        return $false
    } catch { return $false } finally { if ($c) { $c.Close() } }
}
function Test-TunelEmExecucao {
    # O .bat pode terminar depois de abrir o tunnelto em outro processo.
    # A vida do lancador nao determina a vida do tunel.
    if (Get-Process -Name 'tunnelto' -ErrorAction SilentlyContinue) { return $true }
    return [bool]($script:TunelProc -and -not $script:TunelProc.HasExited)
}
function Test-TunelConectado {
    # TCP confirma a conexao ao servidor, mas nao garante que o app responde.
    # Erro de consulta deve ser indefinido, nunca uma queda confirmada.
    try {
        $procs = Get-Process -Name 'tunnelto' -ErrorAction SilentlyContinue
        if (-not $procs) { return $null }
        $ids = @($procs | ForEach-Object { $_.Id })
        # Enumerar antes de filtrar evita o erro CIM "nenhum objeto encontrado"
        # de -State/-OwningProcess quando nao ha conexoes correspondentes.
        $conns = Get-NetTCPConnection -ErrorAction Stop |
                 Where-Object { $_.State -eq 'Established' -and ($ids -contains $_.OwningProcess) -and
                     $_.RemoteAddress -notmatch '^(127\.|::ffff:127\.)' -and
                     $_.RemoteAddress -notin @('::1','0.0.0.0','::') }
        return [bool]$conns
    } catch { return $null }
}
function Test-TunelPublico {
    param([string]$Url,[int]$TimeoutSec=10)
    $r = Invoke-Probe -Url $Url -TimeoutSec $TimeoutSec -SeguirRedirecionamentos
    $portal = Get-ProbePortal -Probe $r -Url $Url
    # O app pode ter seu proprio login. Fora das sondas, um campo password
    # sozinho nao prova portal cativo; exija contexto de rede ou portal conhecido.
    if ($portal -and ($portal.Motivo -in @('endereco do portal','portal informado na resposta','HTTP 511 exige autenticacao') -or
        $r.Body -match '(?i)captive\s+portal|portal\s+cativo')) {
        return @{ Ok=$false; Definitivo=$false; Detalhe='resposta publica exige autenticacao; verificacao inconclusiva' }
    }
    if ($r.UrlFinal -and ([Uri]$r.UrlFinal).Host -ne ([Uri]$Url).Host) {
        return @{ Ok=$false; Definitivo=$false; Detalhe='URL publica redirecionou para outro host; verificacao inconclusiva' }
    }
    # O servidor tunnelto tambem devolve 404 quando nao existe cliente ligado.
    # Diferencie essa resposta do 404 normal de uma rota inexistente do app.
    if (($r.Status -eq 404 -and ([string]$r.Body).Trim() -eq 'Error: Tunnel Not Found') -or
        ($r.Status -eq 500 -and ([string]$r.Body).Trim() -eq 'Error: Error finding tunnel')) {
        return @{ Ok=$false; Definitivo=$true; Detalhe=("HTTP {0} servidor nao encontrou o tunel" -f $r.Status) }
    }
    if ($r.Status -in @(502,503,504,522,523,524)) {
        return @{ Ok=$false; Definitivo=$true; Status=$r.Status; Detalhe=("HTTP {0} tunel sem resposta" -f $r.Status) }
    }
    # 404/405 sao respostas validas de apps que nao possuem GET na raiz.
    if ($r.Status -ge 200 -and $r.Status -lt 600 -and $r.Status -notin @(301,302,303,307,308,407)) {
        return @{ Ok=$true; Definitivo=$true; ErroApp=($r.Status -ge 500); Detalhe=("HTTP {0} (app respondeu)" -f $r.Status) }
    }
    return @{ Ok=$false; Definitivo=$false; Detalhe=("checagem publica inconclusiva: HTTP {0}; {1}" -f $r.Status,$r.Erro) }
}
function Test-SaudeTunel {
    param($Cfg)
    $local = Test-PortaLocal -Porta $Cfg.PortaLocal
    $conectado = Test-TunelConectado
    $pub = @{ Ok=$false; Definitivo=$false; Detalhe='app local indisponivel' }
    $estado = 'APP_INDISPONIVEL'; $reiniciar = $false
    $detalhe = "app local na porta $($Cfg.PortaLocal) nao responde"
    if ($local) {
        $pub = Test-TunelPublico -Url $Cfg.UrlPublica
        if ($pub.Ok) {
            $estado = if ($pub.ErroApp) { 'APP_ERRO' } else { 'FUNCIONANDO' }
            $detalhe = $pub.Detalhe
        } elseif ($pub.Definitivo) {
            $estado = 'FALHA_PUBLICA'; $detalhe = $pub.Detalhe; $reiniciar = $true
            if ($pub.Status -in @(502,503,504)) {
                # Esses codigos tambem podem vir do app. Compare a mesma rota
                # local antes de atribuir o erro ao tunel.
                $caminho = ([Uri]$Cfg.UrlPublica).PathAndQuery
                $urlLocal = "http://127.0.0.1:{0}{1}" -f $Cfg.PortaLocal,$caminho
                $app = Invoke-Probe -Url $urlLocal
                $respostaLocal = $false
                try { $finalLocal = [Uri]$app.UrlFinal; $respostaLocal = $finalLocal.Host -eq '127.0.0.1' -and $finalLocal.Port -eq $Cfg.PortaLocal } catch {}
                if ($respostaLocal -and $app.Status -eq $pub.Status) {
                    $estado = 'APP_ERRO'; $detalhe = "app local e publico responderam HTTP $($pub.Status)"; $reiniciar = $false
                } elseif ($app.Status -eq 0) {
                    $estado = 'APP_INDISPONIVEL'; $detalhe = 'porta local aberta, mas o app nao respondeu ao HTTP'; $reiniciar = $false
                }
            }
        } elseif ($conectado -eq $true) {
            $estado = 'CONECTADO'; $detalhe = "saida TCP estabelecida; $($pub.Detalhe)"
        } elseif ($conectado -eq $false) {
            $estado = 'SEM_CONEXAO'; $detalhe = 'tunnelto sem conexao TCP de saida'; $reiniciar = $true
        } else {
            $estado = 'INDEFINIDO'; $detalhe = "consulta TCP indisponivel; $($pub.Detalhe)"
        }
    }
    return @{ Estado=$estado; Detalhe=$detalhe; Reiniciar=$reiniciar; Local=$local; Conectado=$conectado; Publico=$pub }
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
    $proc = Get-Process -Name 'tunnelto' -ErrorAction SilentlyContinue
    $saude = Test-SaudeTunel -Cfg $Cfg
    $conn = $saude.Conectado; $pub = $saude.Publico
    Write-Log ("Internet   : {0} ({1})" -f $est.Estado,$est.Detalhe) 'INFO'
    Write-Log ("Processo   : {0}" -f ($(if($proc){"tunnelto rodando (PID $(($proc | ForEach-Object { $_.Id }) -join ','))"}else{'NAO esta rodando'}))) 'INFO'
    Write-Log ("Tunel conex: {0}" -f ($(if($conn -eq $true){'CONECTADO (saida estabelecida)'}elseif($conn -eq $false){'SEM conexao de saida'}else{'indefinido'}))) 'INFO'
    Write-Log ("App local  : porta {0} -> {1}" -f $Cfg.PortaLocal,($(if($saude.Local){'OK'}else{'nao responde'}))) 'INFO'
    Write-Log ("Tunel publ.: {0} -> {1} ({2})" -f $Cfg.UrlPublica,($(if($pub.Ok){'OK'}elseif($pub.Definitivo){'FALHA CONFIRMADA'}else{'INCONCLUSIVO'})),$pub.Detalhe) 'INFO'
    Write-Log ("Resultado  : {0} ({1})" -f $saude.Estado,$saude.Detalhe) $(if($saude.Estado -in @('FUNCIONANDO','CONECTADO')){'OK'}else{'AVISO'})
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
                    if ($estadoAnterior -ne 'CATIVO') { $quedasPortal++ }
                    Write-Log ("[ciclo {0}] PORTAL CATIVO (queda #{1}). Recuperando..." -f $ciclo,$quedasPortal) 'AVISO'
                    if ($estadoAnterior -ne 'CATIVO' -and $est.PortalUrl) { $cap=Salvar-CapturaPortal -Url $est.PortalUrl; if ($cap) { Write-Log ("Captura automatica: {0}" -f $cap) 'INFO' } }
                    Invoke-Login -Cfg $Cfg -PortalUrl $est.PortalUrl | Out-Null
                    Start-Sleep -Seconds 3
                    $est = Testar-Conexao -Cfg $Cfg
                    if ($est.Estado -eq 'ONLINE') { Write-Log 'Portal recuperado: internet voltou.' 'OK' }
                    else { Write-Log ("Login ainda sem confirmacao: {0} ({1})." -f $est.Estado,$est.Detalhe) 'AVISO' }
                }
                $estadoAnterior = $est.Estado
            }

            # ---- 2) TUNEL ----
            $tunelInfo = 'desligado'
            if ($Cfg.GerenciarTunel -and -not $SemTunel) {
                $vivo = Test-TunelEmExecucao
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
                    $tunelInfo = 'INICIANDO (aguardando a primeira verificacao)'
                }
                else {
                    # Verifique o tunel mesmo se a sonda de internet falhou.
                    # Uma impressao pode funcionar com a sonda Microsoft bloqueada.
                    $saude = Test-SaudeTunel -Cfg $Cfg
                    $tunelInfo = "{0} ({1})" -f $saude.Estado,$saude.Detalhe
                    if ($saude.Reiniciar -and $est.Estado -in @('CATIVO','OFFLINE')) {
                        $falhasTunel = 0
                        $tunelInfo = "aguardando internet ({0}); {1}" -f $est.Estado,$saude.Detalhe
                    }
                    elseif ($saude.Reiniciar) {
                        $falhasTunel++
                        Write-Log ("[ciclo {0}] Falha do tunel: {1} [{2}/{3}]." -f $ciclo,$saude.Detalhe,$falhasTunel,$Cfg.FalhasParaReiniciar) 'AVISO'
                        if ($falhasTunel -ge $Cfg.FalhasParaReiniciar) {
                            $reinicios++
                            Reiniciar-Tunel -Cfg $Cfg -Motivo ("{0} (reinicio #{1})" -f $saude.Detalhe,$reinicios)
                            $script:ProximaChecagemTunel = (Get-Date).AddSeconds($Cfg.GraceAposReinicioSeg)
                            $falhasTunel = 0; $tunelInfo = 'REABERTO (estava travado)'
                        }
                    }
                    else {
                        $falhasTunel = 0
                    }
                }
            }

            # ---- 3) STATUS ----
            $nivel='OK'
            if ($tunelInfo -match 'reaberto|travad|SEM_CONEXAO|FALHA_PUBLICA|APP_INDISPONIVEL|APP_ERRO|INDEFINIDO|INICIANDO|aguardando' -or $est.Estado -in @('CATIVO','OFFLINE','INDEFINIDO')) { $nivel='AVISO' }
            Write-Log ("[ciclo {0}] internet: {1} ({2}) | tunel: {3}" -f $ciclo,$est.Estado,$est.Detalhe,$tunelInfo) $nivel
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
