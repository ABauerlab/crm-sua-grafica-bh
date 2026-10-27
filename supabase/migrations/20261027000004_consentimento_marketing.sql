-- Consentimento para mensagens promocionais (LGPD + política da Meta).
-- 'none' = sem registro (não enviar promoções), 'opted_in' = autorizou, 'opted_out' = pediu para parar.
alter table public.contacts
  add column marketing_consent text not null default 'none'
    check (marketing_consent in ('none', 'opted_in', 'opted_out')),
  add column marketing_consent_at timestamptz,
  add column marketing_consent_source text
    check (marketing_consent_source in ('whatsapp', 'manual', 'formulario', 'loja', 'outro')),
  add constraint contacts_marketing_consent_at_check
    check (marketing_consent = 'none' or marketing_consent_at is not null);
