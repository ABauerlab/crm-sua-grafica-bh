# Banners da home (imagens)

Os banners do carrossel da loja são **imagens JPG** em `ecommerce/public/banners/` (versão larga 1920x640 e de celular 1000x800).

Para mudar um texto: edite `gerar.py` e rode, nesta pasta:

```bash
python3 gerar.py   # monta os HTMLs temporários em ./html
node render.cjs    # renderiza com o Playwright e grava os JPG na loja
```

Usa a fonte Inter (instalada no sistema), o símbolo da marca e os recortes de produto em `recortes/` (fotos do catálogo com o fundo branco removido). Só afirme nos banners o que a loja cumpre: pedido pago até 10h30 em dia útil, cobertura de orçamento comprovado, 2x sem juros e frete grátis na região central.
