#Requires -Version 5.1
<#
================================================================================
  Rede-DualHomed.ps1  (OPCIONAL - rode so se a ponte "congelar" apos reconectar)
  --------------------------------------------------------------------------
  Sua maquina tem DUAS redes ao mesmo tempo:
    - Cabo (Ethernet)  -> rede interna, so para falar com as impressoras Zebra
    - Wi-Fi            -> internet, para o tunel (tunn.dev / Vercel)

  Quando o Wi-Fi cai, o Windows as vezes passa a mandar a internet pelo CABO,
  que nao tem saida -> tudo "congela" mesmo depois do portal reconectar.

  Este script mostra o diagnostico e, se voce confirmar, ajusta para:
    - Wi-Fi com PRIORIDADE (metrica baixa) = rota padrao da internet
    - Ethernet SEM gateway padrao, apenas com ROTA ESTATICA para as impressoras

  >>> NADA e alterado sem voce digitar o numero da placa e confirmar. <<<
  Precisa ser ADMINISTRADOR. Anote os valores atuais antes (ele mostra tudo).
================================================================================
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

function Teste-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not (Teste-Admin)) {
    Write-Host 'Precisa rodar como ADMINISTRADOR (botao direito no PowerShell > Executar como administrador).' -ForegroundColor Red
    return
}

Write-Host '==== DIAGNOSTICO ATUAL (copie isto antes de mudar nada) ====' -ForegroundColor Cyan
Write-Host ''
Write-Host '--- Interfaces e metricas ---' -ForegroundColor Yellow
Get-NetIPInterface -AddressFamily IPv4 |
    Select-Object ifIndex, InterfaceAlias, ConnectionState, InterfaceMetric, AutomaticMetric |
    Sort-Object InterfaceMetric | Format-Table -AutoSize

Write-Host '--- Rotas padrao (0.0.0.0/0) ---' -ForegroundColor Yellow
Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
    Select-Object ifIndex, InterfaceAlias, NextHop, RouteMetric | Format-Table -AutoSize

Write-Host '--- Enderecos IPv4 ---' -ForegroundColor Yellow
Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -notlike '169.254*' -and $_.IPAddress -ne '127.0.0.1' } |
    Select-Object ifIndex, InterfaceAlias, IPAddress, PrefixLength | Format-Table -AutoSize

Write-Host ''
Write-Host 'Nenhuma alteracao foi feita. Para AJUSTAR, responda as perguntas abaixo.' -ForegroundColor Green
Write-Host '(Para so ver o diagnostico, feche agora.)' -ForegroundColor DarkGray
Write-Host ''

$resp = Read-Host 'Deseja ajustar as metricas/rotas agora? (digite SIM para continuar)'
if ($resp -ne 'SIM') { Write-Host 'Cancelado. Nada alterado.' -ForegroundColor Yellow; return }

$ifWifi = Read-Host 'ifIndex da placa Wi-Fi (coluna ifIndex da tabela acima)'
$ifEth  = Read-Host 'ifIndex da placa CABO/Ethernet interna (impressoras)'
$redeImp = Read-Host 'Rede das impressoras em CIDR (ex: 10.41.0.0/16). Enter p/ pular rota estatica'

try {
    Write-Host "Definindo Wi-Fi (ifIndex $ifWifi) com prioridade (metrica 10)..." -ForegroundColor Cyan
    Set-NetIPInterface -ifIndex ([int]$ifWifi) -AddressFamily IPv4 -InterfaceMetric 10 -ErrorAction Stop

    Write-Host "Reduzindo prioridade do cabo (ifIndex $ifEth, metrica 50)..." -ForegroundColor Cyan
    Set-NetIPInterface -ifIndex ([int]$ifEth) -AddressFamily IPv4 -InterfaceMetric 50 -ErrorAction Stop

    # Remove rota padrao que porventura exista no cabo (impede o "buraco negro")
    $rotaEth = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Where-Object { $_.ifIndex -eq [int]$ifEth }
    if ($rotaEth) {
        Write-Host 'Removendo rota padrao do cabo (ela mandava internet para o buraco negro)...' -ForegroundColor Cyan
        $rotaEth | Remove-NetRoute -Confirm:$false
    } else {
        Write-Host 'Cabo ja nao tinha rota padrao. Otimo.' -ForegroundColor Green
    }

    if ($redeImp.Trim()) {
        Write-Host "Adicionando rota estatica persistente $redeImp pelo cabo (ifIndex $ifEth)..." -ForegroundColor Cyan
        # Descobre o gateway do cabo, se houver; senao usa on-link (0.0.0.0)
        $nh = (Get-NetIPConfiguration -InterfaceIndex ([int]$ifEth) -ErrorAction SilentlyContinue).IPv4DefaultGateway.NextHop
        if (-not $nh) { $nh = '0.0.0.0' }
        New-NetRoute -DestinationPrefix $redeImp.Trim() -InterfaceIndex ([int]$ifEth) -NextHop $nh -RouteMetric 1 -PolicyStore PersistentStore -ErrorAction Stop | Out-Null
        Write-Host "Rota estatica criada (NextHop $nh)." -ForegroundColor Green
    }

    Write-Host ''
    Write-Host 'Pronto. Resultado agora:' -ForegroundColor Green
    Get-NetIPInterface -AddressFamily IPv4 | Select-Object ifIndex, InterfaceAlias, InterfaceMetric | Sort-Object InterfaceMetric | Format-Table -AutoSize
    Write-Host 'Teste: a internet deve sair pelo Wi-Fi e as impressoras continuarem acessiveis pelo cabo.' -ForegroundColor Cyan
} catch {
    Write-Host "ERRO ao ajustar: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'Me envie esta mensagem que eu ajusto o comando.' -ForegroundColor Yellow
}
