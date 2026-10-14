#Requires -Version 5.1
<#
Regressoes offline, sem Pester nem acesso a rede/processos reais.
Execute na raiz do repositorio:
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Mapanto.Tests.ps1
  pwsh.exe -NoProfile -File .\tests\Mapanto.Tests.ps1

Somente as definicoes de funcoes do supervisor sao carregadas pelo AST. Nao
executa o dispatch, o mutex, a criacao de Logs, login ou inicio do tunnelto.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path $PSScriptRoot -Parent) 'Mapanto.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw ($parseErrors | Out-String) }
$definitions = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
. ([scriptblock]::Create(($definitions | ForEach-Object { $_.Extent.Text }) -join "`r`n"))

# Fail closed if a scenario accidentally reaches an unmocked real operation.
function Invoke-WebRequest { throw 'Teste chamou HTTP sem mock.' }
function Get-Process { throw 'Teste consultou processos sem mock.' }
function Get-NetTCPConnection { throw 'Teste consultou TCP sem mock.' }
function Start-Process { throw 'Teste tentou iniciar um processo.' }
function Stop-Process { throw 'Teste tentou parar um processo.' }
function Start-Sleep { throw 'Teste tentou aguardar.' }
function Write-Log { param($Msg, $Nivel) }

if (-not ('MapantoTestResponseException' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
public sealed class MapantoTestResponseException : Exception {
    public object Response { get; private set; }
    public MapantoTestResponseException(object response) : base("HTTP simulado") { Response = response; }
}
'@
}
Add-Type -AssemblyName System.Net.Http

$script:Passed = 0
$script:Failed = 0
$script:TunelProc = $null

function Assert-Equal {
    param($Actual, $Expected, [string]$Message = '')
    if ($null -eq $Expected) {
        if ($null -ne $Actual) { throw "Esperado null; recebido '$Actual'. $Message" }
    } elseif ($null -eq $Actual -or $Actual -ne $Expected) {
        throw "Esperado '$Expected'; recebido '$Actual'. $Message"
    }
}
function Assert-True {
    param($Value, [string]$Message = '')
    if ($Value -ne $true) { throw "Esperado true. $Message" }
}
function Assert-False {
    param($Value, [string]$Message = '')
    if ($Value -ne $false) { throw "Esperado false. $Message" }
}
function Invoke-Test {
    param([string]$Name, [scriptblock]$Body)
    try {
        # Each scenario has its own function/mock scope.
        . $Body
        $script:Passed++
        Write-Host "PASS $Name" -ForegroundColor Green
    } catch {
        $script:Failed++
        Write-Host "FAIL $Name : $($_.Exception.Message)" -ForegroundColor Red
    } finally { $script:TunelProc = $null }
}
function New-ProbeResult {
    param([int]$Status = 200, [string]$Body = '', [string]$Location = '', [string]$UrlFinal = '', [string]$Erro = '')
    [pscustomobject]@{ Status=$Status; Body=$Body; Location=$Location; UrlFinal=$UrlFinal; Headers=@{}; ContentHeaders=@{}; Erro=$Erro }
}
function New-TestConfig {
    $cfg = Get-ConfigPadrao
    $cfg.SondaUrl = 'http://www.msftconnecttest.com/connecttest.txt'
    $cfg.SondaTextoOk = 'Microsoft Connect Test'
    $cfg.SondaRedirectUrl = 'http://www.msftconnecttest.com/redirect'
    $cfg.SondasAlternativas = @([pscustomobject]@{ Url='https://www.gstatic.com/generate_204'; Status=204; Texto='' })
    $cfg.UrlPublica = 'https://mapanto.tunn.dev'
    $cfg.PortaLocal = 8080
    return $cfg
}

Invoke-Test 'Config inclui sonda HTTPS alternativa' {
    $cfg = Get-ConfigPadrao
    Assert-True (@($cfg.SondasAlternativas | Where-Object { $_.Url -match '^https://' -and $_.Status -eq 204 }).Count -gt 0)
}
Invoke-Test 'Config antiga com subdominio diferente corrige URL publica padrao' {
    function Test-Path { param($Path); $true }
    $cfg = New-TestConfig
    $cfg.Subdomain = 'minha-impressora'
    $cfg.TunnelBat = 'C:\tests\iniciar-tunel.bat'
    $r = Resolver-Tunel -Cfg $cfg
    Assert-Equal $r.UrlPublica 'https://minha-impressora.tunn.dev'
}
Invoke-Test 'Config com URL publica personalizada preserva dominio' {
    function Test-Path { param($Path); $true }
    $cfg = New-TestConfig
    $cfg.Subdomain = 'minha-impressora'
    $cfg.TunnelBat = 'C:\tests\iniciar-tunel.bat'
    $cfg.UrlPublica = 'https://impressao.example/mapa'
    $r = Resolver-Tunel -Cfg $cfg
    Assert-Equal $r.UrlPublica 'https://impressao.example/mapa'
}

Invoke-Test 'Microsoft esperado reconhece ONLINE' {
    function Invoke-Probe { param($Url, $TimeoutSec, [switch]$SeguirRedirecionamentos); New-ProbeResult -Status 200 -Body "Microsoft Connect Test`r`n" -UrlFinal $Url }
    $r = Testar-Conexao -Cfg (New-TestConfig)
    Assert-Equal $r.Estado 'ONLINE'
    Assert-Equal $r.PortalUrl $null
}
Invoke-Test 'Microsoft 403 e HTTPS204 reconhece ONLINE sem falso portal' {
    function Invoke-Probe {
        param($Url, $TimeoutSec, [switch]$SeguirRedirecionamentos)
        if ($Url -match 'gstatic') { return New-ProbeResult -Status 204 -UrlFinal $Url }
        New-ProbeResult -Status 403 -Body 'Forbidden' -UrlFinal $Url
    }
    Assert-Equal (Testar-Conexao -Cfg (New-TestConfig)).Estado 'ONLINE'
}
Invoke-Test 'Microsoft corpo inesperado sem evidencia fica INDEFINIDO' {
    function Invoke-Probe { param($Url, $TimeoutSec, [switch]$SeguirRedirecionamentos); New-ProbeResult -Status 200 -Body '<html>Resposta alterada pelo proxy.</html>' -UrlFinal $Url }
    $r = Testar-Conexao -Cfg (New-TestConfig)
    Assert-Equal $r.Estado 'INDEFINIDO'
    Assert-Equal $r.PortalUrl $null
}
Invoke-Test '403 generico nao e portal cativo' {
    function Invoke-Probe { param($Url, $TimeoutSec, [switch]$SeguirRedirecionamentos); New-ProbeResult -Status 403 -Body 'Forbidden' -UrlFinal $Url }
    Assert-Equal (Testar-Conexao -Cfg (New-TestConfig)).Estado 'INDEFINIDO'
}
Invoke-Test 'Texto esperado em HTML injetado nao e suficiente' {
    function Invoke-Probe { param($Url, $TimeoutSec, [switch]$SeguirRedirecionamentos); New-ProbeResult -Status 200 -Body '<html>Microsoft Connect Test</html>' -UrlFinal $Url }
    Assert-Equal (Testar-Conexao -Cfg (New-TestConfig)).Estado 'INDEFINIDO'
}
Invoke-Test 'Redirect normal Microsoft para MSN nao e portal' {
    function Invoke-Probe {
        param($Url, $TimeoutSec, [switch]$SeguirRedirecionamentos)
        if ($Url -match '/redirect$') { return New-ProbeResult -Status 302 -Location 'https://www.msn.com/' -UrlFinal $Url }
        New-ProbeResult -Status 0 -Erro 'timeout' -UrlFinal $Url
    }
    Assert-Equal (Testar-Conexao -Cfg (New-TestConfig)).Estado 'INDEFINIDO'
}
Invoke-Test 'Fallback204 vence redirect antigo do portal' {
    function Invoke-Probe {
        param($Url, $TimeoutSec, [switch]$SeguirRedirecionamentos)
        if ($Url -match 'gstatic') { return New-ProbeResult -Status 204 -UrlFinal $Url }
        New-ProbeResult -Status 302 -Location 'https://portal.zooxwifi.com/login' -UrlFinal $Url
    }
    $r = Testar-Conexao -Cfg (New-TestConfig)
    Assert-Equal $r.Estado 'ONLINE'
    Assert-Equal $r.PortalUrl $null
}
Invoke-Test 'Zoox real bloqueando sondas reconhece CATIVO' {
    function Invoke-Probe { param($Url, $TimeoutSec, [switch]$SeguirRedirecionamentos); New-ProbeResult -Status 302 -Location 'https://portal.zooxwifi.com/login' -UrlFinal $Url }
    $r = Testar-Conexao -Cfg (New-TestConfig)
    Assert-Equal $r.Estado 'CATIVO'
    Assert-Equal $r.PortalUrl 'https://portal.zooxwifi.com/login'
}
Invoke-Test 'Zoox no HTML reconhece CATIVO' {
    function Invoke-Probe { param($Url, $TimeoutSec, [switch]$SeguirRedirecionamentos); New-ProbeResult -Status 200 -Body '<html><a href="https://portal.zooxwifi.com/login">Acessar WiFi</a></html>' -UrlFinal $Url }
    $r = Testar-Conexao -Cfg (New-TestConfig)
    Assert-Equal $r.Estado 'CATIVO'
    Assert-Equal $r.PortalUrl 'https://portal.zooxwifi.com/login'
}
Invoke-Test 'Internet recuperada e reconhecida apos portal' {
    $script:InternetRecuperada = $false
    function Invoke-Probe {
        param($Url, $TimeoutSec, [switch]$SeguirRedirecionamentos)
        if ($script:InternetRecuperada) {
            if ($Url -match 'gstatic') { return New-ProbeResult -Status 204 -UrlFinal $Url }
            return New-ProbeResult -Status 403 -Body 'Microsoft indisponivel' -UrlFinal $Url
        }
        New-ProbeResult -Status 302 -Location 'https://portal.zooxwifi.com/login' -UrlFinal $Url
    }
    $cfg = New-TestConfig
    Assert-Equal (Testar-Conexao -Cfg $cfg).Estado 'CATIVO'
    $script:InternetRecuperada = $true
    $r = Testar-Conexao -Cfg $cfg
    Assert-Equal $r.Estado 'ONLINE'
    Assert-Equal $r.PortalUrl $null
}
Invoke-Test 'Todas sondas sem resposta HTTP reconhecem OFFLINE' {
    function Invoke-Probe { param($Url, $TimeoutSec, [switch]$SeguirRedirecionamentos); New-ProbeResult -Status 0 -Erro 'rede indisponivel' -UrlFinal $Url }
    $r = Testar-Conexao -Cfg (New-TestConfig)
    Assert-Equal $r.Estado 'OFFLINE'
    Assert-Equal $r.PortalUrl $null
}
Invoke-Test 'Sonda adicional configurada pode confirmar ONLINE' {
    $cfg = New-TestConfig
    $cfg.SondasAlternativas = @([pscustomobject]@{ Url='https://sonda.example/ping'; Status=200; Texto='PONG' })
    function Invoke-Probe {
        param($Url, $TimeoutSec, [switch]$SeguirRedirecionamentos)
        if ($Url -match 'sonda.example') { return New-ProbeResult -Status 200 -Body 'PONG' -UrlFinal $Url }
        New-ProbeResult -Status 403 -UrlFinal $Url
    }
    Assert-Equal (Testar-Conexao -Cfg $cfg).Estado 'ONLINE'
}

Invoke-Test 'TCP de saida real confirma conexao do tunnelto' {
    function Get-Process { param($Name, $ErrorAction); [pscustomobject]@{ Id=912; HasExited=$false } }
    function Get-NetTCPConnection {
        param($State, $ErrorAction)
        Assert-Equal $State $null 'A consulta deve enumerar sem filtro -State.'
        Assert-Equal $ErrorAction 'Stop' 'Erros nao podem virar ausencia de conexao.'
        [pscustomobject]@{ OwningProcess=912; State='Established'; RemoteAddress='203.0.113.20' }
    }
    Assert-True (Test-TunelConectado)
}
Invoke-Test 'Erro Get-NetTCPConnection e inconclusivo, nao falso negativo' {
    function Get-Process { param($Name, $ErrorAction); [pscustomobject]@{ Id=912; HasExited=$false } }
    function Get-NetTCPConnection { param($State, $ErrorAction); throw 'Access denied / CIM indisponivel' }
    Assert-Equal (Test-TunelConectado) $null
}
Invoke-Test 'Processo sem nenhuma conexao retorna false' {
    function Get-Process { param($Name, $ErrorAction); [pscustomobject]@{ Id=912; HasExited=$false } }
    function Get-NetTCPConnection { param($State, $ErrorAction) }
    Assert-False (Test-TunelConectado)
}
Invoke-Test 'Conexoes de outro PID ou sem Established nao confirmam tunel' {
    function Get-Process { param($Name, $ErrorAction); [pscustomobject]@{ Id=912; HasExited=$false } }
    function Get-NetTCPConnection {
        param($State, $ErrorAction)
        [pscustomobject]@{ OwningProcess=99; State='Established'; RemoteAddress='203.0.113.20' }
        [pscustomobject]@{ OwningProcess=912; State='Listen'; RemoteAddress='203.0.113.20' }
        [pscustomobject]@{ OwningProcess=912; State='SynSent'; RemoteAddress='203.0.113.20' }
    }
    Assert-False (Test-TunelConectado)
}
Invoke-Test 'Loopback e enderecos indefinidos nao contam como saida' {
    function Get-Process { param($Name, $ErrorAction); [pscustomobject]@{ Id=912; HasExited=$false } }
    function Get-NetTCPConnection {
        param($State, $ErrorAction)
        foreach ($ip in @('127.0.0.1','127.0.0.2','::1','0.0.0.0','::')) {
            [pscustomobject]@{ OwningProcess=912; State='Established'; RemoteAddress=$ip }
        }
    }
    Assert-False (Test-TunelConectado)
}
Invoke-Test 'Sem processo tunnelto nao inventa falha TCP' {
    function Get-Process { param($Name, $ErrorAction) }
    Assert-Equal (Test-TunelConectado) $null
}
Invoke-Test 'Wrapper encerrado mas tunnelto vivo continua em execucao' {
    $script:TunelProc = [pscustomobject]@{ Id=100; HasExited=$true }
    function Get-Process { param($Name, $ErrorAction); [pscustomobject]@{ Id=912; HasExited=$false } }
    Assert-True (Test-TunelEmExecucao)
}
Invoke-Test 'Launcher vivo aguarda tunnelto entre tentativas' {
    $script:TunelProc = [pscustomobject]@{ Id=100; HasExited=$false }
    function Get-Process { param($Name, $ErrorAction) }
    Assert-True (Test-TunelEmExecucao)
}
Invoke-Test 'Launcher e tunnelto encerrados retornam false' {
    $script:TunelProc = [pscustomobject]@{ Id=100; HasExited=$true }
    function Get-Process { param($Name, $ErrorAction) }
    Assert-False (Test-TunelEmExecucao)
}

Invoke-Test 'Publico HTTP404 da aplicacao confirma funcionamento' {
    function Invoke-Probe {
        param($Url, $TimeoutSec, [switch]$SeguirRedirecionamentos)
        Assert-True $SeguirRedirecionamentos 'Checagem publica deve seguir redirects da aplicacao.'
        New-ProbeResult -Status 404 -Body 'Pagina nao encontrada' -UrlFinal $Url
    }
    $r = Test-TunelPublico -Url 'https://mapanto.tunn.dev'
    Assert-True $r.Ok
    Assert-True $r.Definitivo
}
Invoke-Test 'Publico HTTP502 e falha definitiva' {
    function Invoke-Probe { param($Url, $TimeoutSec, [switch]$SeguirRedirecionamentos); New-ProbeResult -Status 502 -Body 'Bad Gateway' -UrlFinal $Url }
    $r = Test-TunelPublico -Url 'https://mapanto.tunn.dev'
    Assert-False $r.Ok
    Assert-True $r.Definitivo
}
Invoke-Test 'HTTP404 Tunnel Not Found nao e resposta saudavel da aplicacao' {
    function Invoke-Probe { param($Url, $TimeoutSec, [switch]$SeguirRedirecionamentos); New-ProbeResult -Status 404 -Body 'Error: Tunnel Not Found' -UrlFinal $Url }
    $r = Test-TunelPublico -Url 'https://mapanto.tunn.dev'
    Assert-False $r.Ok
    Assert-True $r.Definitivo
}
Invoke-Test 'HTTP500 Error finding tunnel confirma falha do provedor' {
    function Invoke-Probe { param($Url, $TimeoutSec, [switch]$SeguirRedirecionamentos); New-ProbeResult -Status 500 -Body 'Error: Error finding tunnel' -UrlFinal $Url }
    $r = Test-TunelPublico -Url 'https://mapanto.tunn.dev'
    Assert-False $r.Ok
    Assert-True $r.Definitivo
}
Invoke-Test 'HTTP500 generico da aplicacao prova tunel respondendo' {
    function Invoke-Probe { param($Url, $TimeoutSec, [switch]$SeguirRedirecionamentos); New-ProbeResult -Status 500 -Body 'Erro interno da aplicacao de impressao' -UrlFinal $Url }
    $r = Test-TunelPublico -Url 'https://mapanto.tunn.dev'
    Assert-True $r.Ok
    Assert-True $r.Definitivo
    Assert-True $r.ErroApp
}
Invoke-Test 'Redirecionamento publico para outro host e inconclusivo' {
    function Invoke-Probe { param($Url, $TimeoutSec, [switch]$SeguirRedirecionamentos); New-ProbeResult -Status 200 -Body 'Login' -UrlFinal 'https://portal.zooxwifi.com/login' }
    $r = Test-TunelPublico -Url 'https://mapanto.tunn.dev'
    Assert-False $r.Ok
    Assert-False $r.Definitivo
}
Invoke-Test 'TLS local indisponivel e inconclusivo' {
    function Invoke-Probe { param($Url, $TimeoutSec, [switch]$SeguirRedirecionamentos); New-ProbeResult -Status 0 -Erro 'TLS certificate validation failed' -UrlFinal $Url }
    $r = Test-TunelPublico -Url 'https://mapanto.tunn.dev'
    Assert-False $r.Ok
    Assert-False $r.Definitivo
    Assert-True ($r.Detalhe -match 'TLS')
}
Invoke-Test 'Publico HTTP511 nao deve confirmar aplicacao' {
    function Invoke-Probe { param($Url, $TimeoutSec, [switch]$SeguirRedirecionamentos); New-ProbeResult -Status 511 -Body 'WiFi login required' -UrlFinal $Url }
    $r = Test-TunelPublico -Url 'https://mapanto.tunn.dev'
    Assert-False $r.Ok
    Assert-False $r.Definitivo 'Portal nao prova que o tunel deve reiniciar.'
}
Invoke-Test 'Publico HTTP200 com portal injetado no mesmo host e inconclusivo' {
    function Invoke-Probe { param($Url, $TimeoutSec, [switch]$SeguirRedirecionamentos); New-ProbeResult -Status 200 -Body '<a href="https://portal.zooxwifi.com/login">Acessar WiFi</a>' -UrlFinal $Url }
    $r = Test-TunelPublico -Url 'https://mapanto.tunn.dev'
    Assert-False $r.Ok
    Assert-False $r.Definitivo
}
Invoke-Test 'Publico login legitimo da aplicacao confirma resposta do tunel' {
    function Invoke-Probe { param($Url, $TimeoutSec, [switch]$SeguirRedirecionamentos); New-ProbeResult -Status 200 -Body '<form action="/login"><input type="password" name="senha"><button>Entrar</button></form>' -UrlFinal $Url }
    $r = Test-TunelPublico -Url 'https://mapanto.tunn.dev'
    Assert-True $r.Ok 'O login do app nao deve ser confundido com portal que intercepta a sonda.'
    Assert-True $r.Definitivo
}

Invoke-Test 'Saude publica positiva vence falso negativo TCP' {
    function Test-PortaLocal { param($Porta); $true }
    function Test-TunelConectado { $false }
    function Test-TunelPublico { param($Url, $TimeoutSec); @{ Ok=$true; Definitivo=$true; Detalhe='HTTP 200' } }
    $r = Test-SaudeTunel -Cfg (New-TestConfig)
    Assert-Equal $r.Estado 'FUNCIONANDO'
    Assert-False $r.Reiniciar
    Assert-True $r.Local
    Assert-False $r.Conectado
    Assert-True $r.Publico.Ok
}
Invoke-Test 'Saude TCP conectado e TLS inconclusivo preserva tunel' {
    function Test-PortaLocal { param($Porta); $true }
    function Test-TunelConectado { $true }
    function Test-TunelPublico { param($Url, $TimeoutSec); @{ Ok=$false; Definitivo=$false; Detalhe='TLS indisponivel' } }
    $r = Test-SaudeTunel -Cfg (New-TestConfig)
    Assert-Equal $r.Estado 'CONECTADO'
    Assert-False $r.Reiniciar
}
Invoke-Test 'Saude app local fora nao reinicia tunel' {
    function Test-PortaLocal { param($Porta); $false }
    function Test-TunelConectado { $false }
    function Test-TunelPublico { param($Url, $TimeoutSec); @{ Ok=$false; Definitivo=$true; Detalhe='HTTP 502' } }
    $r = Test-SaudeTunel -Cfg (New-TestConfig)
    Assert-Equal $r.Estado 'APP_INDISPONIVEL'
    Assert-False $r.Reiniciar
}
Invoke-Test 'Saude HTTP502 com app local disponivel pede reinicio' {
    function Test-PortaLocal { param($Porta); $true }
    function Test-TunelConectado { $true }
    function Test-TunelPublico { param($Url, $TimeoutSec); @{ Ok=$false; Definitivo=$true; Detalhe='HTTP 502' } }
    $r = Test-SaudeTunel -Cfg (New-TestConfig)
    Assert-Equal $r.Estado 'FALHA_PUBLICA'
    Assert-True $r.Reiniciar
}
Invoke-Test 'Saude sem saida TCP e publico inconclusivo pede reinicio' {
    function Test-PortaLocal { param($Porta); $true }
    function Test-TunelConectado { $false }
    function Test-TunelPublico { param($Url, $TimeoutSec); @{ Ok=$false; Definitivo=$false; Detalhe='timeout' } }
    $r = Test-SaudeTunel -Cfg (New-TestConfig)
    Assert-Equal $r.Estado 'SEM_CONEXAO'
    Assert-True $r.Reiniciar
}
Invoke-Test 'Saude sem evidencia fica INDEFINIDO sem reiniciar' {
    function Test-PortaLocal { param($Porta); $true }
    function Test-TunelConectado { $null }
    function Test-TunelPublico { param($Url, $TimeoutSec); @{ Ok=$false; Definitivo=$false; Detalhe='TLS indisponivel' } }
    $r = Test-SaudeTunel -Cfg (New-TestConfig)
    Assert-Equal $r.Estado 'INDEFINIDO'
    Assert-False $r.Reiniciar
    Assert-Equal $r.Conectado $null
}
Invoke-Test 'Saude HTTP500 do app e APP_ERRO sem reinicio' {
    function Test-PortaLocal { param($Porta); $true }
    function Test-TunelConectado { $false }
    function Invoke-Probe { param($Url, $TimeoutSec, [switch]$SeguirRedirecionamentos); New-ProbeResult -Status 500 -Body 'Erro interno da impressao' -UrlFinal $Url }
    $r = Test-SaudeTunel -Cfg (New-TestConfig)
    Assert-Equal $r.Estado 'APP_ERRO'
    Assert-False $r.Reiniciar
}
Invoke-Test 'Saude HTTP503 do app local e publico nao reinicia tunel conectado' {
    function Test-PortaLocal { param($Porta); $true }
    function Test-TunelConectado { $true }
    function Invoke-Probe {
        param($Url, $TimeoutSec, [switch]$SeguirRedirecionamentos)
        New-ProbeResult -Status 503 -Body 'App em manutencao' -UrlFinal $Url
    }
    $r = Test-SaudeTunel -Cfg (New-TestConfig)
    Assert-Equal $r.Estado 'APP_ERRO'
    Assert-False $r.Reiniciar
}
Invoke-Test 'Saude HTTP503 relay com HTTP200 local confirma falha publica' {
    function Test-PortaLocal { param($Porta); $true }
    function Test-TunelConectado { $true }
    function Invoke-Probe {
        param($Url, $TimeoutSec, [switch]$SeguirRedirecionamentos)
        if (([uri]$Url).Host -eq '127.0.0.1') { return New-ProbeResult -Status 200 -Body 'Mapa disponivel' -UrlFinal $Url }
        New-ProbeResult -Status 503 -Body 'Service Unavailable' -UrlFinal $Url
    }
    $r = Test-SaudeTunel -Cfg (New-TestConfig)
    Assert-Equal $r.Estado 'FALHA_PUBLICA'
    Assert-True $r.Reiniciar
}
Invoke-Test 'Saude porta aberta com timeout HTTP local nao reinicia tunel' {
    function Test-PortaLocal { param($Porta); $true }
    function Test-TunelConectado { $true }
    function Invoke-Probe {
        param($Url, $TimeoutSec, [switch]$SeguirRedirecionamentos)
        if (([uri]$Url).Host -eq '127.0.0.1') { return New-ProbeResult -Status 0 -Erro 'App HTTP timeout' -UrlFinal $Url }
        New-ProbeResult -Status 504 -Body 'Gateway Timeout' -UrlFinal $Url
    }
    $r = Test-SaudeTunel -Cfg (New-TestConfig)
    Assert-Equal $r.Estado 'APP_INDISPONIVEL'
    Assert-False $r.Reiniciar
}
Invoke-Test 'Saude compara a mesma rota e query no app local antes de reiniciar' {
    function Test-PortaLocal { param($Porta); $true }
    function Test-TunelConectado { $true }
    function Invoke-Probe {
        param($Url, $TimeoutSec, [switch]$SeguirRedirecionamentos)
        if (([uri]$Url).Host -eq '127.0.0.1') {
            Assert-Equal $Url 'http://127.0.0.1:8080/mapa?setor=2'
            Assert-False ([bool]$SeguirRedirecionamentos) 'A comparacao local deve preservar a origem da resposta.'
            return New-ProbeResult -Status 502 -Body 'App gateway error' -UrlFinal $Url
        }
        New-ProbeResult -Status 502 -Body 'Bad Gateway' -UrlFinal $Url
    }
    $cfg = New-TestConfig
    $cfg.UrlPublica = 'https://mapanto.tunn.dev/mapa?setor=2'
    $r = Test-SaudeTunel -Cfg $cfg
    Assert-Equal $r.Estado 'APP_ERRO'
    Assert-False $r.Reiniciar
}
Invoke-Test 'Saude nao atribui erro publico ao app quando HTTP local redireciona para URL publica' {
    function Test-PortaLocal { param($Porta); $true }
    function Test-TunelConectado { $true }
    function Invoke-Probe {
        param($Url, $TimeoutSec, [switch]$SeguirRedirecionamentos)
        New-ProbeResult -Status 502 -Body 'Bad Gateway' -UrlFinal 'https://mapanto.tunn.dev/'
    }
    $r = Test-SaudeTunel -Cfg (New-TestConfig)
    Assert-Equal $r.Estado 'FALHA_PUBLICA' 'O erro visto depois do redirect local nao veio do app local.'
    Assert-True $r.Reiniciar
}

Invoke-Test 'Invoke-Probe preserva resposta HTTP de sucesso e URL final' {
    function Invoke-WebRequest {
        [CmdletBinding()]
        param($Uri, $MaximumRedirection, [switch]$UseBasicParsing, $TimeoutSec, $Headers, [switch]$SkipHttpErrorCheck)
        Assert-Equal $MaximumRedirection 0
        Assert-Equal $ErrorActionPreference 'SilentlyContinue'
        Assert-True $SkipHttpErrorCheck 'Preserva corpos HTTP quando o cmdlet suporta essa opcao.'
        [pscustomobject]@{
            StatusCode=200; Headers=@{}; Content='Microsoft Connect Test'
            BaseResponse=[pscustomobject]@{ ResponseUri=[uri]$Uri }
        }
    }
    $r = Invoke-Probe -Url 'http://www.msftconnecttest.com/connecttest.txt'
    Assert-Equal $r.Status 200
    Assert-Equal $r.Body 'Microsoft Connect Test'
    Assert-Equal $r.UrlFinal 'http://www.msftconnecttest.com/connecttest.txt'
}
Invoke-Test 'Invoke-Probe pode seguir redirecionamentos para app publico' {
    function Invoke-WebRequest {
        [CmdletBinding()]
        param($Uri, $MaximumRedirection, [switch]$UseBasicParsing, $TimeoutSec, $Headers, [switch]$SkipHttpErrorCheck)
        Assert-True ($MaximumRedirection -gt 0)
        [pscustomobject]@{ StatusCode=200; Headers=@{}; Content='ok'; BaseResponse=[pscustomobject]@{ ResponseUri=[uri]'https://mapanto.tunn.dev/mapa' } }
    }
    $r = Invoke-Probe -Url 'https://mapanto.tunn.dev' -SeguirRedirecionamentos
    Assert-Equal $r.Status 200
    Assert-Equal $r.UrlFinal 'https://mapanto.tunn.dev/mapa'
}
Invoke-Test 'Invoke-Probe le corpo e Location HttpResponseMessage (PowerShell7)' {
    function Invoke-WebRequest {
        [CmdletBinding()]
        param($Uri, $MaximumRedirection, [switch]$UseBasicParsing, $TimeoutSec, $Headers, [switch]$SkipHttpErrorCheck)
        # .NET Framework enum lacks a named 511 member, although HTTP supports it.
        $status = [Enum]::ToObject([System.Net.HttpStatusCode], 511)
        $response = New-Object System.Net.Http.HttpResponseMessage $status
        $response.Content = New-Object System.Net.Http.StringContent '<a href="https://portal.zooxwifi.com/login">WiFi</a>'
        $response.Headers.Location = [uri]'https://portal.zooxwifi.com/login'
        $response.RequestMessage = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::Get), ([uri]$Uri)
        throw (New-Object MapantoTestResponseException $response)
    }
    $r = Invoke-Probe -Url 'http://www.msftconnecttest.com/connecttest.txt'
    Assert-Equal $r.Status 511
    Assert-Equal ([string]$r.Location) 'https://portal.zooxwifi.com/login'
    Assert-True ($r.Body -match 'zooxwifi')
}
Invoke-Test 'Invoke-Probe le corpo e Location WebResponse (PowerShell5)' {
    function Invoke-WebRequest {
        [CmdletBinding()]
        param($Uri, $MaximumRedirection, [switch]$UseBasicParsing, $TimeoutSec, $Headers)
        $response = [pscustomobject]@{
            StatusCode=302; Headers=@{ Location='https://portal.zooxwifi.com/login' }; ResponseUri=[uri]$Uri
        }
        $response | Add-Member -MemberType ScriptMethod -Name GetResponseStream -Value {
            return New-Object IO.MemoryStream (,[Text.Encoding]::UTF8.GetBytes('Portal ZooxWiFi'))
        }
        throw (New-Object MapantoTestResponseException $response)
    }
    $r = Invoke-Probe -Url 'http://www.msftconnecttest.com/connecttest.txt'
    Assert-Equal $r.Status 302
    Assert-Equal ([string]$r.Location) 'https://portal.zooxwifi.com/login'
    Assert-Equal $r.Body 'Portal ZooxWiFi'
}
Invoke-Test 'Invoke-Probe informa falha de transporte sem resposta HTTP' {
    function Invoke-WebRequest { throw 'TLS certificate validation failed' }
    $r = Invoke-Probe -Url 'https://mapanto.tunn.dev'
    Assert-Equal $r.Status 0
    Assert-True ($r.Erro -match 'TLS')
}
Invoke-Test 'Invoke-Probe preserva HTTP302 emitido junto de erro nao terminante' {
    function Invoke-WebRequest {
        [CmdletBinding()]
        param($Uri, $MaximumRedirection, [switch]$UseBasicParsing, $TimeoutSec, $Headers)
        Write-Error 'Maximum redirection count exceeded (PowerShell 5.1)'
        [pscustomobject]@{
            StatusCode=302; Headers=@{ Location='https://portal.zooxwifi.com/login' }; Content='Login WiFi'
            BaseResponse=[pscustomobject]@{ ResponseUri=[uri]$Uri }
        }
    }
    $r = Invoke-Probe -Url 'http://www.msftconnecttest.com/connecttest.txt'
    Assert-Equal $r.Status 302
    Assert-Equal $r.Location 'https://portal.zooxwifi.com/login'
    Assert-Equal $r.Body 'Login WiFi'
}
Invoke-Test 'Invoke-Probe preserva resposta HTTP capturada por ErrorVariable' {
    function Invoke-WebRequest {
        [CmdletBinding()]
        param($Uri, $MaximumRedirection, [switch]$UseBasicParsing, $TimeoutSec, $Headers)
        $response = [pscustomobject]@{ StatusCode=404; Headers=@{}; ResponseUri=[uri]$Uri }
        $response | Add-Member -MemberType ScriptMethod -Name GetResponseStream -Value {
            return New-Object IO.MemoryStream (,[Text.Encoding]::UTF8.GetBytes('Error: Tunnel Not Found'))
        }
        Write-Error -Exception (New-Object MapantoTestResponseException $response)
    }
    $r = Invoke-Probe -Url 'https://mapanto.tunn.dev'
    Assert-Equal $r.Status 404
    Assert-Equal $r.Body 'Error: Tunnel Not Found'
}
Invoke-Test 'Invoke-Probe converte corpo byte array em texto UTF8' {
    function Invoke-WebRequest {
        [CmdletBinding()]
        param($Uri, $MaximumRedirection, [switch]$UseBasicParsing, $TimeoutSec, $Headers, [switch]$SkipHttpErrorCheck)
        [pscustomobject]@{ StatusCode=404; Headers=@{}; Content=[Text.Encoding]::UTF8.GetBytes('Error: Tunnel Not Found'); BaseResponse=[pscustomobject]@{ RequestMessage=[pscustomobject]@{ RequestUri=[uri]$Uri } } }
    }
    $r = Invoke-Probe -Url 'https://mapanto.tunn.dev'
    Assert-Equal $r.Status 404
    Assert-Equal $r.Body 'Error: Tunnel Not Found'
    Assert-Equal $r.UrlFinal 'https://mapanto.tunn.dev/'
}

function Invoke-SupervisorScenario {
    param([string]$Internet = 'ONLINE', [string[]]$EstadosSaude = @('FUNCIONANDO'), [int]$Ciclos = 1, [switch]$RecuperarPortal)
    $script:TestInternet = $Internet
    $script:TestEstadosSaude = $EstadosSaude
    $script:TestCiclosMax = $Ciclos
    $script:TestCiclos = 0
    $script:TestInicios = 0
    $script:TestReinicios = 0
    $script:TestSaudes = 0
    $script:TestRecuperarPortal = $RecuperarPortal
    $script:TestLog = New-Object 'System.Collections.Generic.List[string]'
    function Mostrar-Cabecalho { param($Cfg) }
    function Write-Log { param($Msg, $Nivel); $script:TestLog.Add([string]$Msg) }
    function Write-LogErro { param($Err, $Contexto); throw "Erro inesperado no supervisor: $($Err.Exception.Message)" }
    function Get-Process { param($Name, $ErrorAction); [pscustomobject]@{ Id=912; HasExited=$false } }
    function Iniciar-Tunel {
        param($Cfg)
        $script:TestInicios++
        # Simula .bat que termina depois de iniciar um tunnelto independente.
        $script:TunelProc = [pscustomobject]@{ Id=100; HasExited=$true }
        $script:UltimoInicioTunel = Get-Date
    }
    function Reiniciar-Tunel { param($Cfg, $Motivo); $script:TestReinicios++ }
    function Testar-Conexao { param($Cfg); @{ Estado=$script:TestInternet; PortalUrl='https://portal.zooxwifi.com/login'; Detalhe='sonda simulada' } }
    function Salvar-CapturaPortal { param($Url) }
    function Invoke-Login {
        param($Cfg, $PortalUrl)
        if ($script:TestRecuperarPortal) { $script:TestInternet = 'ONLINE' }
        $true
    }
    function Test-SaudeTunel {
        param($Cfg)
        $script:TestSaudes++
        $i = [Math]::Min($script:TestCiclos, $script:TestEstadosSaude.Count - 1)
        $estado = $script:TestEstadosSaude[$i]
        [pscustomobject]@{ Estado=$estado; Detalhe='checagem simulada'; Reiniciar=($estado -in @('SEM_CONEXAO','FALHA_PUBLICA')) }
    }
    function Start-Sleep {
        param([int]$Seconds, [int]$Milliseconds)
        if ($Seconds -eq 31) {
            $script:TestCiclos++
            if ($script:TestCiclos -ge $script:TestCiclosMax) { throw 'MAPANTO_TEST_FIM' }
        }
    }
    $cfg = New-TestConfig
    $cfg.IntervaloSegundos = 31
    $cfg.GraceAposReinicioSeg = 0
    $cfg.FalhasParaReiniciar = 2
    try { Iniciar-Supervisor -Cfg $cfg }
    catch { if ($_.Exception.Message -ne 'MAPANTO_TEST_FIM') { throw } }
    [pscustomobject]@{ Inicios=$script:TestInicios; Reinicios=$script:TestReinicios; Saudes=$script:TestSaudes; Logs=$script:TestLog }
}
Invoke-Test 'Supervisor reconhece FUNCIONANDO mesmo com sonda INDEFINIDO' {
    $r = Invoke-SupervisorScenario -Internet 'INDEFINIDO' -EstadosSaude @('FUNCIONANDO')
    Assert-Equal $r.Inicios 1
    Assert-Equal $r.Saudes 1 'A sonda nao deve impedir checagem do tunel.'
    Assert-Equal $r.Reinicios 0
    Assert-True (@($r.Logs | Where-Object { $_ -match 'tunel: FUNCIONANDO' }).Count -gt 0)
}
Invoke-Test 'Supervisor preserva tunnelto vivo quando wrapper ja terminou' {
    $r = Invoke-SupervisorScenario -EstadosSaude @('CONECTADO') -Ciclos 2
    Assert-Equal $r.Inicios 1 'O fim do launcher nao deve reabrir o tunnelto.'
    Assert-Equal $r.Saudes 2
    Assert-Equal $r.Reinicios 0
}
Invoke-Test 'Supervisor confirma publico mesmo com sondas OFFLINE' {
    $r = Invoke-SupervisorScenario -Internet 'OFFLINE' -EstadosSaude @('FUNCIONANDO')
    Assert-Equal $r.Saudes 1
    Assert-Equal $r.Reinicios 0
    Assert-True (@($r.Logs | Where-Object { $_ -match 'tunel: FUNCIONANDO' }).Count -gt 0)
}
Invoke-Test 'Supervisor reinicia somente apos limite de falhas consecutivas' {
    $r = Invoke-SupervisorScenario -EstadosSaude @('SEM_CONEXAO') -Ciclos 2
    Assert-Equal $r.Saudes 2
    Assert-Equal $r.Reinicios 1
}
Invoke-Test 'Supervisor zera falhas quando funcionamento volta' {
    $r = Invoke-SupervisorScenario -EstadosSaude @('SEM_CONEXAO','FUNCIONANDO','SEM_CONEXAO') -Ciclos 3
    Assert-Equal $r.Saudes 3
    Assert-Equal $r.Reinicios 0
}
Invoke-Test 'Supervisor aguarda rede OFFLINE sem reiniciar tunel repetidamente' {
    $r = Invoke-SupervisorScenario -Internet 'OFFLINE' -EstadosSaude @('SEM_CONEXAO') -Ciclos 3
    Assert-Equal $r.Saudes 3
    Assert-Equal $r.Reinicios 0
    Assert-True (@($r.Logs | Where-Object { $_ -match 'aguardando internet' }).Count -gt 0)
}
Invoke-Test 'Supervisor confirma recuperacao depois do login no portal' {
    $r = Invoke-SupervisorScenario -Internet 'CATIVO' -EstadosSaude @('FUNCIONANDO') -RecuperarPortal
    Assert-Equal $r.Reinicios 0
    Assert-True (@($r.Logs | Where-Object { $_ -match 'Portal recuperado: internet voltou' }).Count -gt 0)
    Assert-True (@($r.Logs | Where-Object { $_ -match 'internet: ONLINE.*tunel: FUNCIONANDO' }).Count -gt 0)
}
Invoke-Test 'Supervisor exibe INDEFINIDO quando nao ha confirmacao' {
    $r = Invoke-SupervisorScenario -EstadosSaude @('INDEFINIDO') -Ciclos 2
    Assert-Equal $r.Reinicios 0
    Assert-True (@($r.Logs | Where-Object { $_ -match 'tunel: INDEFINIDO' }).Count -gt 0)
}

Write-Host ("`nPowerShell {0}: {1} passou; {2} falhou." -f $PSVersionTable.PSVersion, $script:Passed, $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
exit 0
