# CRM Sua Gráfica BH

CRM de atendimento via WhatsApp Cloud API (Meta). Detalhes técnicos em [CLAUDE.md](CLAUDE.md).

## 1. Cadastrar os segredos no Supabase
Painel do Supabase › projeto › **Edge Functions › Secrets** › *Add new secret*. Cadastre (os valores você pega na Meta; **não os envie em chats nem commite**):

| Nome | Onde achar |
|---|---|
| `WHATSAPP_TOKEN` | Meta for Developers › WhatsApp › API Setup (use um token **permanente** de usuário do sistema em produção) |
| `WHATSAPP_PHONE_NUMBER_ID` | WhatsApp › API Setup › *Phone number ID* |
| `WHATSAPP_WABA_ID` | WhatsApp › API Setup › *WhatsApp Business Account ID* |
| `META_APP_SECRET` | App › Settings › Basic › *App secret* |
| `WHATSAPP_VERIFY_TOKEN` | Invente uma string longa e aleatória; use a mesma no passo 3 |

## 2. Primeiro administrador
1. Painel › **Authentication › Users › Add user** (e-mail + senha, marque *Auto Confirm*).
2. Painel › **Authentication › Sign In / Providers**: desligue **Allow new users to sign up** (cadastro público desativado).
3. No **SQL Editor**, rode (trocando o e-mail e o nome):
```sql
insert into public.profiles (id, name, role)
select id, 'Seu Nome', 'admin' from auth.users where email = 'seu@email.com';
```
Depois, novos atendentes são criados pela tela **Atendentes** (só admin).

## 3. Configurar o webhook na Meta
1. Meta for Developers › seu app › **WhatsApp › Configuration › Webhook › Edit**.
2. **Callback URL**: `https://bhlosshvwmlyzhbghsrc.supabase.co/functions/v1/whatsapp-webhook`
3. **Verify token**: o mesmo valor de `WHATSAPP_VERIFY_TOKEN`. Clique em *Verify and save*.
4. Em *Webhook fields*, assine (**Subscribe**) o campo **`messages`**.
5. Teste enviando uma mensagem ao número: ela deve aparecer em *Conversas*.

## 4. Rodar o front
```bash
npm install
cp .env.example .env   # VITE_SUPABASE_URL e VITE_SUPABASE_ANON_KEY (Supabase › Settings › API)
npm run dev
```

## 5. Usar
Entre com o admin, abra **Templates › Sincronizar** para trazer os templates aprovados. Fora da janela de 24h só é possível enviar templates.

## Páginas legais
`/privacidade` e `/termos` têm texto **provisório** (marcado na página) e precisam de revisão antes de informar as URLs na Meta.
