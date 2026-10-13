# ReconectarWifi — mantém o Wi-Fi corporativo (portal Zoox) vivo

Mantém sua sessão do portal cativo **ZooxWiFi** autenticada automaticamente,
para o túnel **tunn.dev** e as impressoras **Zebra** não caírem a cada ~12h.

Tudo em **PowerShell puro** — não precisa instalar Node, Puppeteer nem nada.

---

## Arquivos

| Arquivo | Para quê |
|---|---|
| `ReconectarWifi.ps1` | O programa principal (menu de Wi-Fi + monitor + login + logs). |
| `Instalar-TarefaInicial.ps1` | (Opcional) faz ele iniciar sozinho no login do Windows. |
| `Rede-DualHomed.ps1` | (Opcional) conserta o roteamento cabo+Wi-Fi se "congelar". |
| `config.json` | Criado sozinho — guarda o Wi-Fi escolhido e as opções. |
| `Logs\` | Criado sozinho — logs diários (é daqui que você copia pra me mandar). |

---

## Passo a passo (primeira vez)

1. Abra o **PowerShell** na pasta `WifiReconect`.
   (No Explorer: clique na barra de endereço, digite `powershell`, Enter.)

2. Libere a execução **só nesta janela**:
   ```powershell
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
   ```

3. Escolha seu Wi-Fi na lista (ele **salva** a escolha):
   ```powershell
   .\ReconectarWifi.ps1 -Configurar
   ```
   > Se o Wi-Fi salvo não estiver no alcance depois, ele **mostra a lista de novo** sozinho.

4. Teste uma vez para ver o estado atual:
   ```powershell
   .\ReconectarWifi.ps1 -Verificar
   ```

5. Deixe o monitor rodando:
   ```powershell
   .\ReconectarWifi.ps1
   ```
   Pode fechar com `Ctrl+C`. Para rodar sozinho sempre, veja "Iniciar automático".

---

## Quando a conexão cair (importante — 1 captura e fica 100%)

O login só com HTTP funciona se o botão **"Próximo"** for um formulário simples.
Se for JavaScript, o monitor avisa no log e você faz **uma captura** pra mim:

**No momento em que a conexão estiver caída** (tela "Bem-vindo de volta Pedro Assis!"):
```powershell
.\ReconectarWifi.ps1 -Capturar
```
Isso gera um arquivo em `Logs\captura-portal-....txt`.
**Abra, `Ctrl+A`, `Ctrl+C` e me mande o conteúdo.** Com ele eu monto o
"login exato" e você cola no `config.json` → aí fica automático de vez.

> Melhor ainda (se puder): no navegador aberto no portal, tecle **F12** →
> aba **Network** → marque **Preserve log** → clique em **Próximo** →
> clique direito em qualquer linha → **Save all as HAR** → me mande o `.har`.
> O HAR me dá o pedido exato de autenticação.

---

## Ver / me enviar os logs

```powershell
.\ReconectarWifi.ps1 -Logs 150
```
Ou abra o arquivo direto: `Logs\reconect-AAAA-MM-DD.log`.
**Todo erro** é gravado num bloco marcado `===== ERRO =====` — copie esse bloco
e me mande que eu identifico e corrijo.

---

## Iniciar automático (não depender de janela aberta)

PowerShell **como Administrador**, na pasta:
```powershell
.\Instalar-TarefaInicial.ps1
```
Inicia no seu login e se reinicia sozinho se cair. Para começar agora:
```powershell
Start-ScheduledTask -TaskName ReconectarWifiZoox
```
Para remover: `.\Instalar-TarefaInicial.ps1 -Remover`

---

## Se "congelar" mesmo depois de reconectar (cabo x Wi-Fi)

Rode (como Administrador) **só para ver o diagnóstico**:
```powershell
.\Rede-DualHomed.ps1
```
Ele mostra as métricas/rotas e **só muda algo se você digitar `SIM`** e informar
os números das placas. Serve para forçar a internet a sair pelo Wi-Fi e manter
as impressoras acessíveis pelo cabo.

---

## Ajustes finos (`config.json`)

- `IntervaloSegundos` — de quanto em quanto tempo checa (padrão 30s).
- `SSID` — nome do Wi-Fi salvo (mude pelo menu `-Configurar`).
- `ReconectarWifi` — se deve reconectar o Wi-Fi sozinho.
- `LoginReplay` — **eu preencho** depois da sua captura.

---

## Proteção no site da Vercel (recomendado)

Enquanto o monitor reconecta (segundos), um comando pode falhar. Veja
`exemplo-retry-vercel.js` para enviar o ZPL com **re-tentativa automática**,
assim nenhuma etiqueta se perde durante a reconexão.
