/*
 * exemplo-retry-vercel.js
 * ------------------------------------------------------------------
 * Trecho para o SEU site (HTML/CSS/JS na Vercel) enviar o ZPL para a
 * impressora Zebra atraves do tunel COM re-tentativa automatica.
 *
 * Durante os poucos segundos em que o portal cativo reconecta, o tunel
 * pode recusar o pedido. Esta funcao espera e tenta de novo (backoff),
 * em vez de perder a etiqueta. Troque a URL pela do seu tunn.dev.
 * ------------------------------------------------------------------
 */

async function enviarZplComRetry(zpl, {
  url = "https://SUA-URL.tunn.dev/endpoint-zebra",
  tentativas = 6,
  esperaInicialMs = 1500,
} = {}) {
  let espera = esperaInicialMs;

  for (let i = 1; i <= tentativas; i++) {
    try {
      const resp = await fetch(url, {
        method: "POST",
        headers: { "Content-Type": "text/plain" },
        body: zpl,
      });

      if (resp.ok) {
        console.log(`[Zebra] enviado na tentativa ${i}`);
        return true;
      }
      console.warn(`[Zebra] tentativa ${i}: HTTP ${resp.status}`);
    } catch (err) {
      // Tunel fora do ar durante a reconexao do portal cativo.
      console.warn(`[Zebra] tentativa ${i} falhou: ${err.message}. Nova tentativa em ${espera}ms`);
    }

    if (i < tentativas) {
      await new Promise((r) => setTimeout(r, espera));
      espera = Math.min(espera * 2, 30000); // dobra ate no maximo 30s
    }
  }

  throw new Error("Nao foi possivel enviar o ZPL: tunel/portal indisponivel apos varias tentativas.");
}

// Exemplo de uso:
// const zpl = "^XA^FO50,50^ADN,36,20^FDOla Zebra^FS^XZ";
// enviarZplComRetry(zpl).catch((e) => alert(e.message));

// Para usar em Node/ESM, descomente:
// export { enviarZplComRetry };
