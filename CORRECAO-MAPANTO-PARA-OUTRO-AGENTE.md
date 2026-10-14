# Correção do Mapanto: revisão e aplicação no computador do túnel

Data: 14/10/2026.

Repositório: https://github.com/MoraisPedroo/wifireconect

Branch com a correção: `codex/corrigir-reconhecimento-conexao`.

## Contexto e escopo

O usuário confirmou que usa `INICIAR.bat / Mapanto.ps1`. A impressão pelo
endereço atendido pelo túnel funcionou, mas o supervisor continuava indicando
falha. A correção está no `Mapanto.ps1`; o lançador continua usando esse arquivo.
O script independente `ReconectarWifi.ps1` não recebeu esta alteração.

Arquivos entregues:

- `Mapanto.ps1`: correção da detecção, supervisão e mensagens.
- `README.md`: significado dos estados e execução dos testes.
- `tests/Mapanto.Tests.ps1`: regressões offline, sem dependências externas.
- Este documento: instruções para revisão e aplicação.

## Causas encontradas

1. A checagem de internet dependia exclusivamente do texto de uma sonda da
   Microsoft. Qualquer outro conteúdo era considerado portal cativo; até o
   redirecionamento normal da Microsoft podia ser confundido com login.
2. Quando essa sonda não retornava `ONLINE`, o supervisor deixava de consultar
   a saúde do túnel e mostrava que estava aguardando internet.
3. Erros de `Get-NetTCPConnection` eram silenciados e interpretados como
   ausência de conexão, podendo provocar reinícios desnecessários.
4. A vida do processo lançador `.bat` era usada como vida do túnel, mesmo
   quando o `tunnelto` continuava funcionando em outro processo.
5. Windows PowerShell 5.1 podia perder a resposta 302 com
   `MaximumRedirection=0`; PowerShell 7 podia perder o corpo de respostas HTTP
   de erro. Isso prejudicava a detecção do portal e do erro do servidor.

## O que foi alterado

- `Invoke-Probe` preserva status, corpo, Location e URL final nos dois
  PowerShells. Sondas não seguem redirecionamentos; a consulta pública pode
  seguir até três. Os pedidos solicitam resposta sem cache.
- `Testar-Conexao` confirma status, host e conteúdo esperados. Se a sonda
  Microsoft falhar, tenta `https://www.gstatic.com/generate_204`, esperando
  HTTP 204 e corpo vazio. `SondasAlternativas` permite personalizar essa lista.
- `CATIVO` exige evidência de autenticação de rede. Respostas inesperadas
  ficam `INDEFINIDO`; ausência de resposta de todas as sondas fica `OFFLINE`.
  Redirecionamentos oficiais Microsoft/Bing/MSN não viram portal cativo.
- `Test-TunelEmExecucao` considera o processo real `tunnelto`, além do lançador.
- `Test-TunelConectado` devolve indefinido quando a consulta do Windows falha;
  somente conexões TCP estabelecidas do processo, fora de loopback, contam.
- `Test-SaudeTunel` combina aplicativo local, TCP e consulta pública. A saúde
  é consultada mesmo quando a sonda de internet falha. Uma resposta pública
  válida prevalece sobre a ausência de TCP observada naquele instante.
- HTTP 404/405 do próprio aplicativo confirma que a rota do túnel respondeu.
  A resposta exata `Error: Tunnel Not Found` do servidor é falha confirmada.
  Login legítimo do aplicativo é distinguido de evidência de portal cativo.
- Para HTTP 502/503/504, compara a mesma rota diretamente no aplicativo local,
  sem acompanhar redirecionamento para a internet. Se o erro também for local,
  relata erro do aplicativo e não reinicia o túnel. Se a porta abrir mas HTTP
  local não responder, relata indisponibilidade do aplicativo.
- Reinício por saúde exige falhas confirmadas consecutivas. Resultado
  inconclusivo e erro do aplicativo não contam como falha do túnel; queda de
  rede confirmada aguarda recuperação da internet.
- `Resolver-Tunel` ajusta a URL padrão quando uma configuração antiga possui
  outro subdomínio. Uma URL pública personalizada é preservada.
- Enviar login/formulário deixa de gerar mensagem de recuperação confirmada.
  O supervisor consulta a conectividade novamente antes de anunciar sucesso.

Estados do túnel:

| Estado | Significado |
| --- | --- |
| `FUNCIONANDO` | Aplicativo local acessível e resposta válida pela URL pública. |
| `CONECTADO` | Aplicativo local acessível e TCP de saída ativo; consulta pública inconclusiva. |
| `APP_INDISPONIVEL` | Aplicativo local sem resposta; não reinicia o túnel por isso. |
| `APP_ERRO` | Aplicativo respondeu com erro; não reinicia o túnel por isso. |
| `SEM_CONEXAO` / `FALHA_PUBLICA` | Evidência de falha do túnel; aplica o limite de ciclos antes do reinício. |
| `INDEFINIDO` | Saúde não pôde ser confirmada; não provoca reinício. |

`FUNCIONANDO` confirma a comunicação com o aplicativo; a impressão física
continua sendo o teste final do fluxo completo.

## Verificação realizada

Os testes de regressão carregam apenas as funções pelo AST do PowerShell e
simulam rede/processos. Não iniciam o supervisor nem fazem login real.

Resultado final: **62 testes aprovados, zero falhas**, em Windows PowerShell
5.1.26100.9444 e também em PowerShell 7.6.5. A revisão independente repetiu a
suíte nos dois motores com o mesmo resultado.

Também foram feitos testes HTTP reais com servidor local em ambas as versões:
302 com Location e corpo; 404 com corpo; e redirecionamento seguido até 404
com URL final preservada. As sondas reais Microsoft/HTTPS 204 também foram
verificadas no computador de desenvolvimento.

Para repetir as regressões, na pasta do repositório:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Mapanto.Tests.ps1
pwsh.exe -NoProfile -File .\tests\Mapanto.Tests.ps1
```

O teste de impressão física deve ser realizado no computador que executa o
túnel e acessa as impressoras. Os testes acima não substituem essa validação.

## Aplicação no computador em questão

1. Localize a pasta **realmente usada** pelo `INICIAR.bat` e pelo atalho de
   inicialização automática. Confira o caminho do `Mapanto.ps1` carregado;
   não basta atualizar uma segunda cópia que não é executada.
2. Revise o diff da branch e execute as regressões. Se usar Git, obtenha a
   branch com `git fetch origin` e examine o estado local antes de trocar de
   branch. Não descarte alterações locais.
3. Faça uma cópia de segurança do `Mapanto.ps1` atual fora da pasta do Git.
   Preserve `mapanto-config.json`, `config.json`, o `.bat` original com a chave
   do túnel e os logs. A correção não exige substituir esses arquivos.
4. Baixe o novo `Mapanto.ps1` para uma pasta temporária e confira sua sintaxe
   antes de substituir o arquivo usado pelo computador. Fonte direta:

   https://raw.githubusercontent.com/MoraisPedroo/wifireconect/codex/corrigir-reconhecimento-conexao/Mapanto.ps1

   Para conferir a sintaxe do arquivo baixado:

   ```powershell
   $arquivoNovo = 'C:\caminho\temporario\Mapanto.ps1'
   $tokens = $null
   $erros = $null
   [System.Management.Automation.Language.Parser]::ParseFile(
       $arquivoNovo, [ref]$tokens, [ref]$erros
   ) | Out-Null
   if ($erros.Count) { throw ($erros | Out-String) }
   ```

5. Pare a instância atual do supervisor, substitua somente `Mapanto.ps1` e
   abra novamente `INICIAR.bat`. Configurações antigas recebem os campos novos
   automaticamente ao carregar. Mantenha uma única instância do supervisor.
6. Na pasta ativa, execute:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Mapanto.ps1 -Status
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Mapanto.ps1 -Logs 80
   ```

## Critérios para aceitar a aplicação

- Confirme subdomínio, URL pública e porta do aplicativo utilizados no PC.
- Com o aplicativo funcionando, `-Status` deve indicar `FUNCIONANDO` ou
  `CONECTADO`, conforme a possibilidade de consulta pública desse computador.
- Faça uma impressão pelo mesmo fluxo que o usuário já testou. Confira os
  ciclos seguintes do log: o túnel deve continuar reconhecido, inclusive se
  uma sonda de internet permanecer inconclusiva.
- Confira que não há reinício provocado apenas por sonda bloqueada, falha de
  consulta TCP, encerramento do lançador ou erro do próprio aplicativo.
- Quando ocorrer uma expiração real do portal, confira a sequência: portal
  detectado, login enviado, nova sonda `ONLINE` e saúde do túnel reconhecida.
  Esse cenário pode ser observado na próxima expiração; não é necessário
  interromper uma conexão funcional para testar.

Se precisar reverter, pare o supervisor, restaure a cópia anterior do
`Mapanto.ps1` e abra o mesmo `INICIAR.bat`. Registre o caminho aplicado, os
resultados de `-Status`, a impressão e as linhas relevantes do log, preservando
a chave do túnel e os dados do login fora do relatório.
