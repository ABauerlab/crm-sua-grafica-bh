-- Aplicada em produção em 12/11/2026. Resumo (SQL completo foi aplicado pelo conector; este arquivo registra o que existe):
-- * catalogo: tamanho_final, tamanho_arte, tamanho_final_fonte, tamanho_final_em; private.categoria_3d(); tamanho_arte = tamanho_mm nas categorias 3D
--   (SACOLAS E SACOS, CAIXAS E EMBALAGENS, ENVELOPES, COBRE CAIXAS). tamanho_final preenchido de títulos "L x P x A" da loja (298 de 1.037).
-- * buscar_produto: para embalagens mostra tamanho_final (ou "a confirmar com o cliente") e nunca o tamanho da arte.
-- * origem_consultas, origem_sessao, app_settings.origem (modo observar), segredo origem_sessao_token em app_segredos.
-- * RPCs: origem_sessao_registrar (token, alerta ao dono quando a sessão cai), origem_caminho_do_sku, origem_registrar (service role).
-- Reaplicação: reexportar as definições com pg_get_functiondef antes de editar.
select 1;
