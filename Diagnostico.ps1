#Requires -Version 5.1
<#
================================================================================
  Diagnostico.ps1
  Coleta TUDO sobre a rede/Wi-Fi/portal desta maquina num unico arquivo,
  para voce abrir, copiar (Ctrl+A/Ctrl+C) e me enviar.
  Nao altera nada. Pode rodar sem ser administrador.

  USO:   .\Diagnostico.ps1
================================================================================
#>
$ErrorActionPreference = 'Continue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$raiz = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$arq  = Join-Path $raiz ("diagnostico-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$sb = New-Object System.Text.StringBuilder

function Secao($titulo, $conteudo) {
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('############## ' + $titulo + ' ##############')
    [void]$sb.AppendLine(($conteudo | Out-String).TrimEnd())
}

[void]$sb.AppendLine("DIAGNOSTICO ReconectarWifi - $(Get-Date)")
[void]$sb.AppendLine("Maquina: $env:COMPUTERNAME   Usuario: $env:USERNAME")
[void]$sb.AppendLine("PowerShell: $($PSVersionTable.PSVersion)")

function Coleta([ScriptBlock] $sb) { try { & $sb } catch { "ERRO: $($_.Exception.Message)" } }

Secao 'Get-NetAdapter'            (Coleta { Get-NetAdapter | Select-Object Name,InterfaceDescription,Status,PhysicalMediaType,ifIndex,MacAddress | Format-Table -AutoSize })
Secao 'Get-NetConnectionProfile'  (Coleta { Get-NetConnectionProfile | Select-Object Name,InterfaceAlias,InterfaceIndex,NetworkCategory,IPv4Connectivity })
Secao 'Get-NetIPConfiguration'    (Coleta { Get-NetIPConfiguration | Format-List InterfaceAlias,IPv4Address,IPv4DefaultGateway,DNSServer })
Secao 'Get-NetRoute 0.0.0.0/0'    (Coleta { Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Select-Object ifIndex,InterfaceAlias,NextHop,RouteMetric })
Secao 'Servico WLAN (wlansvc)'    (Coleta { Get-Service wlansvc | Select-Object Name,Status,StartType })
Secao 'netsh wlan show interfaces'(Coleta { netsh wlan show interfaces 2>&1 })
Secao 'netsh wlan show networks'  (Coleta { netsh wlan show networks 2>&1 })

# --- Teste do portal cativo / internet ---
$res = New-Object System.Text.StringBuilder
foreach ($u in @('http://www.msftconnecttest.com/connecttest.txt','http://www.msftconnecttest.com/redirect')) {
    [void]$res.AppendLine("URL: $u")
    try {
        $r = Invoke-WebRequest -Uri $u -MaximumRedirection 0 -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop
        [void]$res.AppendLine("  HTTP $([int]$r.StatusCode)")
        $loc=$null; try{$loc=$r.Headers.Location}catch{}; if($loc){[void]$res.AppendLine("  Location: $loc")}
        $corpo = ($r.Content -replace '\s+',' '); if($corpo.Length -gt 300){$corpo=$corpo.Substring(0,300)+'...'}
        [void]$res.AppendLine("  Body: $corpo")
    } catch {
        $resp=$null; try{$resp=$_.Exception.Response}catch{}
        if($resp){
            [void]$res.AppendLine("  HTTP $([int]$resp.StatusCode)")
            $loc=$null; try{$loc=$resp.Headers['Location']}catch{}; if($loc){[void]$res.AppendLine("  Location: $loc")}
            try{$srd=New-Object IO.StreamReader($resp.GetResponseStream());$b=$srd.ReadToEnd();$srd.Close();$b=($b -replace '\s+',' ');if($b.Length -gt 300){$b=$b.Substring(0,300)+'...'};[void]$res.AppendLine("  Body: $b")}catch{}
        } else { [void]$res.AppendLine("  ERRO: $($_.Exception.Message)") }
    }
    [void]$res.AppendLine('')
}
Secao 'TESTE PORTAL/INTERNET' $res.ToString()

Set-Content -Path $arq -Value $sb.ToString() -Encoding UTF8
Write-Host ''
Write-Host "Diagnostico salvo em:" -ForegroundColor Green
Write-Host "   $arq" -ForegroundColor White
Write-Host ''
Write-Host ">>> Abra esse arquivo, Ctrl+A, Ctrl+C e me envie o conteudo. <<<" -ForegroundColor Cyan
try { notepad $arq } catch {}
