import os
AQUI=os.path.dirname(os.path.abspath(__file__))
os.chdir(AQUI)
R=os.path.join(AQUI,'recortes')
SIMBOLO=os.path.abspath(os.path.join(AQUI,'..','..','ecommerce','public','marca','simbolo.svg'))
FONT="font-family:'Inter',sans-serif"
CSS="""
*{margin:0;padding:0;box-sizing:border-box}
body{%s;overflow:hidden}
.b{position:relative;overflow:hidden;color:#fff}
.glow{position:absolute;border-radius:50%%;filter:blur(2px)}
.pontos{position:absolute;inset:0;background-image:radial-gradient(rgba(255,255,255,.13) 2px,transparent 2.5px);background-size:34px 34px;opacity:.55}
.marca{position:absolute;display:flex;align-items:center;gap:12px;font-weight:900;letter-spacing:.04em}
.marca b{font-weight:900}
h1{font-weight:900;line-height:.98;letter-spacing:-.02em}
.y{color:#FFD500}
.pill{display:inline-flex;align-items:center;gap:14px;border-radius:16px;font-weight:900}
.prod{position:absolute;filter:drop-shadow(0 28px 32px rgba(0,0,0,.38)) drop-shadow(0 6px 8px rgba(0,0,0,.25))}
.sel{position:absolute;border-radius:50%%;display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center;font-weight:900;box-shadow:0 14px 30px rgba(0,0,0,.3)}
"""%FONT

def doc(w,h,corpo,extra=''):
    return f"<!doctype html><html><head><meta charset='utf-8'><style>{CSS}{extra}</style></head><body><div class='b' style='width:{w}px;height:{h}px'>{corpo}</div></body></html>"

def marca(esq,topo,cor='#fff',tam=26):
    return f"<div class='marca' style='left:{esq}px;top:{topo}px;color:{cor};font-size:{tam}px'><img src='file://{SIMBOLO}' style='width:{tam*1.9}px;height:{tam*1.8}px'><span>SUA GRÁFICA <b style='color:{'#E6007E' if cor!='#fff' else '#FFD500'}'>BH</b></span></div>"

def img(nome,l,t,w,rot=0,extra=''):
    return f"<img class='prod' src='file://{R}/{nome}.png' style='left:{l}px;top:{t}px;width:{w}px;transform:rotate({rot}deg);{extra}'>"

def pill(txt,bg='#FFD500',cor='#0b0b0f',size=30,pad='20px 36px'):
    return f"<span class='pill' style='background:{bg};color:{cor};font-size:{size}px;padding:{pad}'>{txt} <span>→</span></span>"

banners={}
# ---------- 1. mesmo dia
bg1="background:radial-gradient(1200px 700px at 78% 40%,#ff4d4d 0%,#E6007E 38%,#8a0049 75%,#3a0021 100%)"
banners['mesmo-dia']={
 'desk':(1920,640,f"""
<div style='position:absolute;inset:0;{bg1}'></div><div class='pontos'></div>
<div class='glow' style='left:1080px;top:-120px;width:820px;height:820px;background:radial-gradient(circle,rgba(255,213,0,.55),rgba(255,213,0,0) 65%)'></div>
{marca(96,54)}
<div style='position:absolute;left:96px;top:140px;width:1000px'>
 <div style='font-size:36px;font-weight:800;opacity:.95'>Pagou até as 10h30?</div>
 <h1 style='font-size:124px;margin-top:10px'>Produzimos<br><span class='y'>hoje mesmo.</span></h1>
 <div style='font-size:28px;font-weight:600;margin-top:22px;opacity:.95;white-space:nowrap'>Em dia útil, pedido pago até as 10h30 entra na produção no mesmo dia.</div>
</div>
<div style='position:absolute;left:96px;top:520px'>{pill('Ver cartões de visita',size=28,pad='16px 30px')}</div>
{img('panfletos',980,100,760,-6)}{img('pastas',1420,250,440,7)}
"""),
 'mob':(1000,800,f"""
<div style='position:absolute;inset:0;{bg1}'></div><div class='pontos'></div>
<div class='glow' style='left:300px;top:380px;width:720px;height:720px;background:radial-gradient(circle,rgba(255,213,0,.5),rgba(255,213,0,0) 65%)'></div>
{marca(56,44,tam=24)}
<div style='position:absolute;left:56px;top:120px;width:880px'>
 <div style='font-size:34px;font-weight:800'>Pagou até as 10h30?</div>
 <h1 style='font-size:112px;margin-top:8px'>Produzimos<br><span class='y'>hoje mesmo.</span></h1>
 <div style='font-size:27px;font-weight:600;margin-top:18px;max-width:760px'>Em dia útil, pedido pago até as 10h30 entra na produção no mesmo dia.</div>
</div>
{img('panfletos',420,500,520,-6)}{img('pastas',120,560,300,6)}
<div style='position:absolute;left:56px;top:700px'></div>
""")}
# ---------- 2. kit da loja
bg2="background:radial-gradient(1100px 700px at 80% 45%,#2fd0ff 0%,#00A6D6 35%,#005f86 75%,#062b44 100%)"
banners['kit-loja']={
 'desk':(1920,640,f"""
<div style='position:absolute;inset:0;{bg2}'></div><div class='pontos'></div>
<div class='glow' style='left:1000px;top:-100px;width:860px;height:860px;background:radial-gradient(circle,rgba(255,255,255,.5),rgba(255,255,255,0) 62%)'></div>
{marca(96,54)}
<div style='position:absolute;left:96px;top:140px;width:980px'>
 <div style='font-size:36px;font-weight:800'>Cartões, adesivos e embalagens</div>
 <h1 style='font-size:118px;margin-top:10px'>Kit completo<br>para a <span class='y'>sua loja.</span></h1>
 <div style='font-size:28px;font-weight:600;margin-top:22px;opacity:.95'>Tudo com a sua marca, em um pedido só.</div>
</div>
<div style='position:absolute;left:96px;top:520px'>{pill('Montar o kit da minha loja',size=28,pad='16px 30px')}</div>
{img('adesivos',1010,120,450,-8)}{img('canecas',1330,120,540,4)}{img('pastas',1380,350,300,-5)}
<div class='sel' style='left:1000px;top:420px;width:190px;height:190px;background:#FFD500;color:#0b0b0f;font-size:30px;line-height:1.05;transform:rotate(-8deg)'><span style='font-size:58px'>2x</span>sem juros<span style='font-size:20px;font-weight:700'>no cartão</span></div>
"""),
 'mob':(1000,800,f"""
<div style='position:absolute;inset:0;{bg2}'></div><div class='pontos'></div>
<div class='glow' style='left:250px;top:360px;width:760px;height:760px;background:radial-gradient(circle,rgba(255,255,255,.45),rgba(255,255,255,0) 62%)'></div>
{marca(56,44,tam=24)}
<div style='position:absolute;left:56px;top:120px;width:880px'>
 <div style='font-size:33px;font-weight:800'>Cartões, adesivos e embalagens</div>
 <h1 style='font-size:104px;margin-top:8px'>Kit completo<br>para a <span class='y'>sua loja.</span></h1>
</div>
{img('adesivos',60,470,300,-8)}{img('canecas',320,500,420,4)}{img('pastas',680,520,280,-5)}
<div class='sel' style='left:760px;top:360px;width:180px;height:180px;background:#FFD500;color:#0b0b0f;font-size:28px;line-height:1.05;transform:rotate(-8deg)'><span style='font-size:54px'>2x</span>sem juros<span style='font-size:19px;font-weight:700'>no cartão</span></div>
""")}
# ---------- 3. cobrimos
bg3="background:linear-gradient(100deg,#FFE04D 0%,#FFD500 38%,#FF9E00 78%,#F26B00 100%)"
banners['cobrimos']={
 'desk':(1920,640,f"""
<div style='position:absolute;inset:0;{bg3}'></div><div class='pontos' style='opacity:.35'></div>
{marca(96,54,cor='#0b0b0f')}
<div style='position:absolute;left:96px;top:130px;width:1200px;color:#0b0b0f'>
 <div style='font-size:38px;font-weight:900'>Achou mais barato?</div>
 <h1 style='font-size:92px;margin-top:10px;white-space:nowrap'>Cobrimos qualquer<br><span style='color:#E6007E'>orçamento comprovado.</span></h1>
 <div style='font-size:27px;font-weight:700;margin-top:20px;white-space:nowrap'>Mande a proposta da concorrência para o mesmo produto e a gente avalia.</div>
</div>
<div style='position:absolute;left:96px;top:520px'>{pill('Enviar orçamento para cobrir',bg='#0b0b0f',cor='#fff',size=28,pad='16px 30px')}</div>
{img('panfletos',1230,100,640,-7)}{img('canecas',1230,330,420,5)}
"""),
 'mob':(1000,800,f"""
<div style='position:absolute;inset:0;{bg3}'></div><div class='pontos' style='opacity:.35'></div>
{marca(56,44,cor='#0b0b0f',tam=24)}
<div style='position:absolute;left:56px;top:120px;width:880px;color:#0b0b0f'>
 <div style='font-size:36px;font-weight:900'>Achou mais barato?</div>
 <h1 style='font-size:84px;margin-top:8px'>Cobrimos qualquer <span style='color:#E6007E'>orçamento comprovado.</span></h1>
</div>
{img('panfletos',430,520,500,-7)}{img('canecas',90,560,310,5)}
""")}
# ---------- 4. frete e retirada
bg4="background:radial-gradient(1100px 700px at 80% 40%,#c2006a 0%,#5b0a3b 40%,#1a0716 75%,#0b0b0f 100%)"
pin="<svg width='%d' height='%d' viewBox='0 0 24 24' fill='#FFD500'><path d='M12 2C8.1 2 5 5.1 5 9c0 5.2 7 13 7 13s7-7.8 7-13c0-3.9-3.1-7-7-7zm0 9.5A2.5 2.5 0 1 1 12 6.5a2.5 2.5 0 0 1 0 5z'/></svg>"
banners['frete-retirada']={
 'desk':(1920,640,f"""
<div style='position:absolute;inset:0;{bg4}'></div><div class='pontos' style='opacity:.35'></div>
<div class='glow' style='left:1050px;top:-60px;width:800px;height:800px;background:radial-gradient(circle,rgba(230,0,126,.55),rgba(230,0,126,0) 65%)'></div>
{marca(96,54)}
<div style='position:absolute;left:96px;top:120px;width:1000px'>
 <div style='font-size:36px;font-weight:800'>Região central de Belo Horizonte</div>
 <h1 style='font-size:112px;margin-top:10px'><span class='y'>Frete grátis</span><br>e retirada na<br>Praça Sete.</h1>
 <div style='font-size:26px;font-weight:600;margin-top:18px;opacity:.9'>Retirada agendada de materiais prontos. Condições do frete no carrinho.</div>
</div>
<div style='position:absolute;left:96px;top:548px'></div>
{img('pastas',1030,130,640,-5)}{img('adesivos',1480,270,360,8)}
<div style='position:absolute;left:1550px;top:70px'>{pin%(130,130)}</div>
"""),
 'mob':(1000,800,f"""
<div style='position:absolute;inset:0;{bg4}'></div><div class='pontos' style='opacity:.35'></div>
{marca(56,44,tam=24)}
<div style='position:absolute;left:56px;top:120px;width:880px'>
 <div style='font-size:33px;font-weight:800'>Região central de Belo Horizonte</div>
 <h1 style='font-size:108px;margin-top:8px'><span class='y'>Frete grátis</span><br>e retirada na<br>Praça Sete.</h1>
</div>
{img('pastas',380,520,460,-5)}{img('adesivos',70,560,250,8)}
<div style='position:absolute;left:780px;top:40px'>{pin%(110,110)}</div>
""")}
os.makedirs('html',exist_ok=True)
for nome,v in banners.items():
    for k,(w,h,corpo) in v.items():
        open(f'html/{nome}-{k}.html','w').write(doc(w,h,corpo))
print([f for f in os.listdir('html')])
