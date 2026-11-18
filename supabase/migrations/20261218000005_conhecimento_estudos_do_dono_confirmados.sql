-- Dono confirmou (18/11/2026): a conferência cobre sangria e corte em todos os pedidos; em fim de ano o argumento é o volume de pedidos (não escassez).
-- Aplicada pelo conector (conhecimento_estudos_do_dono_confirmados). Idempotente. O texto final também está em docs/agente/conhecimento_rodada18.json.
update public.conhecimento set
  fatos = 'Sangria: sobra do fundo além do corte. Área segura: texto, QR code e logo afastados da borda. Moldura rente à borda parece torta porque o corte varia cerca de 1 mm. Pedir 300 dpi, CMYK e fontes em curvas. A equipe confere sangria e corte em todos os pedidos.',
  embedding = null
where slug = 'arq_regras_ouro';

update public.conhecimento set
  resposta_pronta = 'Aqui a equipe confere sangria e corte do arquivo antes de imprimir e avisa se algo estiver fora, pra não sair cortado ou com cor diferente. Quer mandar a arte pra gente olhar?',
  fatos = 'Usar como valor, nunca como ataque ao concorrente. A equipe confere sangria, área segura e corte em todos os pedidos, avisa se notar problema, e a impressão só segue com o ok do cliente.',
  embedding = null
where slug = 'arq_conferencia_valor';

update public.conhecimento set
  titulo = 'Escassez não, volume de pedidos sim',
  quando_usar = 'Quando surgir a ideia de dizer últimas unidades, estoque acabando ou promoção acabando, ou em datas de pico como fim de ano.',
  resposta_pronta = 'Nessa época entra muito pedido, então aprovar cedo ajuda a garantir a sua data. Fechando agora, a produção já começa e fica tudo certinho pra vc.',
  fatos = 'A gráfica produz sob encomenda: não existe estoque acabando nem últimas unidades, e nunca prometer vaga limitada. Pode dizer a verdade de que em fim de ano e datas de pico entra muito pedido, como prova social e motivo para aprovar cedo. Prazo sempre da ferramenta.',
  embedding = null
where slug = 'escassez_nao_usar';

update public.conhecimento set revisar = false, revisado_em = now() where fonte = 'Estudos do dono (18/11/2026)';
