#Requires -Version 5.1
<#
================================================================================
  Instalar-TarefaInicial.ps1
  Registra o monitor como TAREFA DO WINDOWS para iniciar sozinho no login
  e reiniciar se cair. Assim nao depende de voce deixar a janela aberta.

  USO (clique direito no PowerShell > "Executar como administrador"):
     .\Instalar-TarefaInicial.ps1            # instala/atualiza a tarefa
     .\Instalar-TarefaInicial.ps1 -Remover   # remove a tarefa

  A tarefa chama o ReconectarWifi.ps1 que esta NESTA MESMA pasta.
================================================================================
#>
[CmdletBinding()]
param([switch] $Remover)

$ErrorActionPreference = 'Stop'
$NomeTarefa = 'ReconectarWifiZoox'
$Raiz    = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$Script  = Join-Path $Raiz 'ReconectarWifi.ps1'

function Teste-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Teste-Admin)) {
    Write-Host 'Precisa rodar como ADMINISTRADOR.' -ForegroundColor Red
    Write-Host 'Feche, clique com o botao direito no PowerShell e escolha "Executar como administrador".' -ForegroundColor Yellow
    return
}

if ($Remover) {
    try {
        Unregister-ScheduledTask -TaskName $NomeTarefa -Confirm:$false -ErrorAction Stop
        Write-Host "Tarefa '$NomeTarefa' removida." -ForegroundColor Green
    } catch {
        Write-Host "Nao encontrei a tarefa '$NomeTarefa' (ou erro): $($_.Exception.Message)" -ForegroundColor Yellow
    }
    return
}

if (-not (Test-Path $Script)) {
    Write-Host "Nao achei o ReconectarWifi.ps1 em: $Raiz" -ForegroundColor Red
    return
}

$acao    = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Script`""
$gatilho = New-ScheduledTaskTrigger -AtLogOn
$cfg     = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -StartWhenAvailable -RestartInterval (New-TimeSpan -Minutes 1) -RestartCount 9999 `
            -ExecutionTimeLimit ([TimeSpan]::Zero)
$princ   = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $NomeTarefa -Action $acao -Trigger $gatilho -Settings $cfg -Principal $princ -Force | Out-Null
Write-Host "Tarefa '$NomeTarefa' instalada. Ela inicia no seu login e se reinicia sozinha." -ForegroundColor Green
Write-Host "Para iniciar agora sem reiniciar o PC:" -ForegroundColor Cyan
Write-Host "   Start-ScheduledTask -TaskName $NomeTarefa" -ForegroundColor White
Write-Host "Logs em: $(Join-Path $Raiz 'Logs')" -ForegroundColor Cyan
