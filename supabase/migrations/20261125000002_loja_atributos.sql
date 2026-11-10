
-- Nome de exibição de cada subcategoria: o trecho real que aparece nos títulos da vitrine (com acento e espaço)
do $$
declare r record; t record; w text[]; i integer; j integer; n integer; acc text; achou boolean; v_nome text;
begin
  create temp table if not exists tt_titulos on commit drop as
    select distinct categoria_slug, titulo, private.loja_norm(titulo) n from public.ecommerce_products where ativo;
  for r in select id, categoria_slug, nome_norm, nome_menu from public.loja_subcategorias where nome is null loop
    achou := false; v_nome := null;
    for t in select titulo from tt_titulos x where x.categoria_slug = r.categoria_slug and x.n like '%' || r.nome_norm || '%' limit 3 loop
      w := regexp_split_to_array(t.titulo, '\s+'); n := coalesce(array_length(w, 1), 0);
      for i in 1..n loop
        acc := '';
        for j in i..n loop
          acc := acc || private.loja_norm(w[j]);
          if acc = r.nome_norm then v_nome := rtrim(array_to_string(w[i:j], ' '), ','); achou := true; exit; end if;
          exit when position(acc in r.nome_norm) <> 1;
        end loop;
        exit when achou;
      end loop;
      exit when achou;
    end loop;
    update public.loja_subcategorias set nome = coalesce(v_nome, initcap(lower(r.nome_menu))), slug = private.slugify(coalesce(v_nome, r.nome_menu)) where id = r.id;
  end loop;
end $$;

-- Definição e rótulos das facetas
insert into public.loja_facetas_def (faceta, valor, rotulo, ordem) values
 ('tipo','liso','Papéis lisos (Couchê, Offset)',1),('tipo','rustico','Rústicos e sustentáveis (Kraft, Reciclato)',2),('tipo','nobre','Linha nobre e texturados',3),('tipo','sintetico','Sintéticos e especiais (PVC, BOPP, Acrílico)',4),
 ('gram','leve','Leve (menos de 150g)',1),('gram','medio','Médio (150g a 250g)',2),('gram','encorpado','Encorpado (251g a 350g)',3),('gram','extra','Extra espesso (acima de 350g)',4),
 ('acab','hot-stamping','Hot Stamping (metalizado)',1),('acab','relevo','Relevo seco / Letterpress',2),('acab','uv','Verniz UV',3),('acab','soft-touch','Laminação Soft Touch (aveludado)',4),('acab','fosca','Laminação fosca',5),('acab','brilho','Laminação brilho',6),('acab','holografica','Laminação holográfica',7),('acab','padrao','Sem laminação / padrão',8),
 ('formato','retangular','Retangular',1),('formato','quadrado','Quadrado',2),('formato','arredondado','Cantos arredondados',3),('formato','faca-especial','Faca de corte especial',4),
 ('prazo','express','Express (até 24h)',1),('prazo','padrao','Padrão (2 a 4 dias úteis)',2),('prazo','especial','Especial (5 dias úteis ou mais)',3),
 ('preco','ate-50','Até R$ 50',1),('preco','50-150','R$ 50 a R$ 150',2),('preco','150-500','R$ 150 a R$ 500',3),('preco','500-mais','Acima de R$ 500',4),
 ('material','couche','Couchê',1),('material','offset','Offset / Sulfite',2),('material','duplex','Duplex',3),('material','kraft','Kraft',4),('material','reciclato','Reciclato',5),('material','apergaminhado','Apergaminhado',6),('material','supremo','Supremo',7),
 ('material','pvc','PVC',8),('material','bopp','BOPP',9),('material','acrilico','Acrílico',10),('material','polionda','Polionda',11),('material','psai','PSAI',12),('material','neoplex','Neoplex',13),('material','mdf','MDF',14),('material','acm','ACM',15),('material','vinil','Vinil',16),('material','tecido','Tecido (Oxford e outros)',17),('material','lona','Lona',18)
on conflict (faceta, valor) do update set rotulo = excluded.rotulo, ordem = excluded.ordem;

-- Sinônimos da linguagem do cliente, traduzidos em filtros
insert into public.loja_sinonimos (padrao, faceta, valor) values
 ('papel grosso|grosso|encorpado|firme', 'gram', 'encorpado'),
 ('aveludad|toque suave|soft touch|softtouch', 'acab', 'soft-touch'),
 ('metalizad|dourad|pratead|cobre|brilhante|hot stamping', 'acab', 'hot-stamping'),
 ('holograf', 'acab', 'holografica'),
 ('papel marrom|marrom|kraft', 'material', 'kraft'),
 ('reciclad|ecologic|sustentavel|reciclato', 'tipo', 'rustico'),
 ('relevo|letterpress', 'acab', 'relevo'),
 ('verniz|uv localizado', 'acab', 'uv'),
 ('fosco|fosca', 'acab', 'fosca'),
 ('cantos arredondados|canto arredondado|arredondado', 'formato', 'arredondado'),
 ('urgente|expresso|express|rapido', 'prazo', 'express')
on conflict (padrao) do nothing;


-- Atributos de filtro de cada opção da vitrine (calculados do título; sem custo, margem nem piso)
create or replace view private.loja_atributos as
select e.sku, e.ref, e.produto_slug, e.categoria_slug, e.titulo, e.preco, e.parcela_2x, e.prazo_dias_uteis, e.quantidade, e.busca, e.fotos,
       md5(e.categoria_slug || '|' || e.titulo) modelo,
       s.slug sub, s.nome sub_nome, m.material,
       case when m.material in ('couche','offset','duplex') then 'liso'
            when m.material in ('kraft','reciclato','apergaminhado') then 'rustico'
            when m.material = 'supremo' then 'nobre'
            when m.material is not null then 'sintetico' end tipo,
       case when g.gram is null then null when g.gram < 150 then 'leve' when g.gram <= 250 then 'medio' when g.gram <= 350 then 'encorpado' else 'extra' end gram,
       a.acab,
       case when x.tt ~ 'arredondad' then 'arredondado' when x.tt ~ '(corte-(com-formato-)?(especial|personalizado)|faca)' then 'faca-especial'
            when d.l is not null and d.l = d.a then 'quadrado' else 'retangular' end formato,
       case when e.prazo_dias_uteis <= 1 then 'express' when e.prazo_dias_uteis <= 4 then 'padrao' else 'especial' end prazo,
       case when e.preco < 50 then 'ate-50' when e.preco < 150 then '50-150' when e.preco < 500 then '150-500' else '500-mais' end preco_faixa
  from public.ecommerce_products e
 cross join lateral (select private.slugify(e.titulo) tt, private.loja_norm(e.titulo) n, private.loja_norm(e.categoria) c) x
 cross join lateral (select case when left(x.n, length(x.c)) = x.c then substr(x.n, length(x.c) + 1) else x.n end rest) r
  left join lateral (select ss.slug, ss.nome from public.loja_subcategorias ss
                      where ss.categoria_slug = e.categoria_slug and position(ss.nome_norm in x.n) > 0
                      order by (position(ss.nome_norm in r.rest) = 1) desc, length(ss.nome_norm) desc, ss.ordem limit 1) s on true
 cross join lateral (select case
      when x.tt ~ 'bopp' then 'bopp' when x.tt ~ '(^|-)pvc(-|$)' then 'pvc' when x.tt ~ 'acrilico' then 'acrilico' when x.tt ~ 'polionda' then 'polionda'
      when x.tt ~ '(^|-)psai(-|$)' then 'psai' when x.tt ~ 'neoplex' then 'neoplex' when x.tt ~ '(^|-)mdf(-|$)' then 'mdf' when x.tt ~ '(^|-)acm(-|$)' then 'acm'
      when x.tt ~ 'vinil' then 'vinil' when x.tt ~ '(oxford|cacharrel|elastano|tactel|tecido)' then 'tecido' when x.tt ~ '(^|-)lona(s)?(-|$)' then 'lona'
      when x.tt ~ 'kraft' then 'kraft' when x.tt ~ 'reciclato' then 'reciclato' when x.tt ~ 'supremo' then 'supremo' when x.tt ~ 'apergaminhado' then 'apergaminhado'
      when x.tt ~ 'couche' then 'couche' when x.tt ~ '(offset|sulfite)' then 'offset' when x.tt ~ 'duplex' then 'duplex' end material) m
 cross join lateral (select substring(x.tt from '(?:^|-)([0-9]{2,3})g(?:-|$)')::integer gram) g
 cross join lateral (select substring(x.tt from '(?:^|-)([0-9]{2,4})x[0-9]{2,4}mm') l, substring(x.tt from '(?:^|-)[0-9]{2,4}x([0-9]{2,4})mm') a) d
 cross join lateral (select case when array_length(z, 1) is null then array['padrao'] else z end acab from (select array_remove(array[
      case when x.tt ~ 'hot-stamping' then 'hot-stamping' end,
      case when x.tt ~ '(relevo|letterpress)' then 'relevo' end,
      case when (x.tt ~ 'verniz' and x.tt !~ 'sem-verniz') or x.tt ~ 'uv-(total|localizado)' then 'uv' end,
      case when x.tt ~ 'soft-touch' then 'soft-touch' end,
      case when x.tt ~ '(lam-fosca|laminacao-fosca)' then 'fosca' end,
      case when x.tt ~ '(lam-brilho|laminacao-brilho)' then 'brilho' end,
      case when x.tt ~ 'hologr' then 'holografica' end], null) z) zz) a
 where e.ativo;
revoke all on private.loja_atributos from public, anon, authenticated;

