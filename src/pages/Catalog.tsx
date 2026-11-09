import { KitsTab } from '@/features/catalog/KitsTab'
import { ProductsTab } from '@/features/catalog/ProductsTab'
import { SemCodigoTab, useSemCodigo } from '@/features/catalog/SemCodigoTab'
import { PriceHealthTab } from '@/features/catalog/PriceHealthTab'
import { FotosTab } from '@/features/catalog/FotosTab'
import { BlogTab } from '@/features/catalog/BlogTab'
import { Tabs, TabsList, TabsTrigger, TabsContent } from '@/components/ui/tabs'

export default function Catalog() {
  const { data: semCodigo } = useSemCodigo()
  const n = semCodigo?.length ?? 0
  return (
    <div className="flex h-full flex-col">
      <header className="border-b px-4 py-3">
        <h1 className="text-xl font-black">Catálogo e Kits</h1>
      </header>
      <Tabs defaultValue="catalogo" className="flex min-h-0 flex-1 flex-col">
        <TabsList>
          <TabsTrigger value="catalogo">Catálogo do fornecedor</TabsTrigger>
          <TabsTrigger value="kits">Kits prontos</TabsTrigger>
          <TabsTrigger value="sem-codigo">Sem código{n > 0 ? ` (${n})` : ''}</TabsTrigger>
          <TabsTrigger value="saude-precos">Saúde de preços</TabsTrigger>
          <TabsTrigger value="fotos">Fotos</TabsTrigger>
          <TabsTrigger value="blog">Blog do site</TabsTrigger>
        </TabsList>
        <TabsContent value="catalogo" className="flex min-h-0 flex-1 flex-col p-0"><ProductsTab /></TabsContent>
        <TabsContent value="kits" className="flex min-h-0 flex-1 flex-col p-0"><KitsTab /></TabsContent>
        <TabsContent value="sem-codigo" className="flex min-h-0 flex-1 flex-col p-0"><SemCodigoTab /></TabsContent>
        <TabsContent value="saude-precos" className="flex min-h-0 flex-1 flex-col p-0"><PriceHealthTab /></TabsContent>
        <TabsContent value="fotos" className="flex min-h-0 flex-1 flex-col p-0"><FotosTab /></TabsContent>
        <TabsContent value="blog" className="flex min-h-0 flex-1 flex-col p-0"><BlogTab /></TabsContent>
      </Tabs>
    </div>
  )
}
