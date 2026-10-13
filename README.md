# wifireconect

Mantém a sessão do portal cativo **ZooxWiFi** autenticada automaticamente, para o
túnel (**tunn.dev**) e as impressoras **Zebra (ZPL)** não caírem a cada ~12 h.
Tudo em **PowerShell puro** — não instala nada.

## Baixar no PC (via PowerShell)

```powershell
cd $HOME\Documents
git clone https://github.com/MoraisPedroo/wifireconect.git
cd wifireconect
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
.\ReconectarWifi.ps1 -Configurar
.\ReconectarWifi.ps1
```

Para **atualizar** depois:

```powershell
cd $HOME\Documents\wifireconect
git pull
```

## Arquivos

| Arquivo | Para quê |
|---|---|
| `ReconectarWifi.ps1` | Programa principal: menu de Wi-Fi + monitor + login + logs. |
| `Instalar-TarefaInicial.ps1` | (Opcional) iniciar sozinho no login do Windows. |
| `Rede-DualHomed.ps1` | (Opcional) conserta roteamento cabo + Wi-Fi. |
| `exemplo-retry-vercel.js` | Retry do envio ZPL no site da Vercel. |
| `LEIA-ME.md` | Passo a passo completo. |

Passo a passo detalhado em **[LEIA-ME.md](LEIA-ME.md)**.
