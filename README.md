# wifireconect

Mantém a sessão do portal cativo **ZooxWiFi** autenticada automaticamente, para o
túnel (**tunn.dev**) e as impressoras **Zebra (ZPL)** não caírem a cada ~12 h.
Tudo em **PowerShell puro** — não instala nada.

## ⭐ Mapanto.ps1 — tudo em um (túnel + Wi-Fi) — RECOMENDADO

`Mapanto.ps1` faz tudo num arquivo só: **inicia e vigia o túnel** (reabre quando
ele cai **e também quando trava sem fechar**) e mantém o portal vivo, com logs.

```powershell
cd "$HOME\Documents\wifireconect-main"
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
.\Mapanto.ps1 -Instalar    # abre sozinho no login (roda com a tela bloqueada)
.\Mapanto.ps1              # ou rode agora
```

Comandos: `-Instalar` / `-Desinstalar` (início automático), `-Status` (checagem
rápida), `-Logs 120` (ver log), `-Capturar` (portal caído). Também há o
`INICIAR.bat` (duplo-clique) que substitui o `Clica aqui no tunel.bat`.

> A chave do túnel fica em `mapanto-config.json` (lido do seu `.bat` na 1ª vez) e
> **nunca vai pro GitHub** (está no `.gitignore`).

---

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
