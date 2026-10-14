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

O documento [Correção para outro agente](CORRECAO-MAPANTO-PARA-OUTRO-AGENTE.md)
detalha as mudanças, a verificação e a aplicação no computador do túnel.

### Como o Mapanto confirma que voltou a funcionar

Rode `./Mapanto.ps1 -Status` para conferir o resultado. O supervisor usa a
sonda da Microsoft e, se ela falhar, uma segunda sonda HTTPS. Resposta
inesperada ou bloqueio de uma sonda aparece como `INDEFINIDO`; só tenta login
quando encontra evidência de portal cativo.

O túnel é verificado mesmo quando a sonda de internet falha:

- `FUNCIONANDO`: o aplicativo local está acessível e respondeu pelo endereço público.
- `CONECTADO`: o aplicativo local está acessível e o tunnelto tem conexão TCP de
  saída; a consulta pública foi inconclusiva, por exemplo por TLS/proxy.
- `APP_INDISPONIVEL`: a porta local configurada não responde. Reiniciar o
  túnel não corrige isso.
- `APP_ERRO`: o aplicativo respondeu com erro, inclusive quando o mesmo
  502/503/504 aparece localmente e pela URL pública. Isso não reinicia o túnel.
- `INDEFINIDO`: não foi possível confirmar a saúde. Esse estado não provoca reinício.

Falhas confirmadas do túnel precisam atingir `FalhasParaReiniciar` ciclos
consecutivos para provocar reinício. O encerramento do `.bat` lançador não
conta como queda se o processo `tunnelto` continua ativo. O envio do formulário
de login só é marcado como recuperação depois de uma nova sonda confirmar a conexão.

`SondasAlternativas` pode ser configurado em `mapanto-config.json` com objetos
`Url`, `Status` e `Texto` esperado. Configurações antigas recebem a segunda
sonda automaticamente ao carregar.

Para executar os testes de regressão sem depender da internet nem abrir o túnel:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Mapanto.Tests.ps1
```

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
