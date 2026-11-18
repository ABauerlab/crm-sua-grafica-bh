/** Banner do checkout: duas artes (computador e celular) com Pix, 2x sem juros e frete grátis na região central. */
export function BannerCheckout() {
  return (
    <picture>
      <source media="(min-width: 768px)" srcSet="/banners/checkout-desktop.jpg" width={1920} height={420} />
      {/* eslint-disable-next-line @next/next/no-img-element */}
      <img src="/banners/checkout-celular.jpg" width={1080} height={620} alt="Pague no Pix ou em até 2x sem juros no cartão. Frete grátis na região central de Belo Horizonte." className="h-auto w-full rounded-xl2" />
    </picture>
  )
}
