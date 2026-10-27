import { KitsTab } from '@/features/catalog/KitsTab'
import { ProductsTab } from '@/features/catalog/ProductsTab'
import { Tabs, TabsList, TabsTrigger, TabsContent } from '@/components/ui/tabs'

export default function Catalog() {
  return (
    <div className="flex h-full flex-col">
      <header className="border-b px-4 py-3">
        <h1 className="text-xl font-black">Catálogo e Kits</h1>
      </header>
      <Tabs defaultValue="catalogo" className="flex min-h-0 flex-1 flex-col">
        <TabsList>
          <TabsTrigger value="catalogo">Catálogo do fornecedor</TabsTrigger>
          <TabsTrigger value="kits">Kits prontos</TabsTrigger>
        </TabsList>
        <TabsContent value="catalogo" className="flex min-h-0 flex-1 flex-col p-0"><ProductsTab /></TabsContent>
        <TabsContent value="kits" className="flex min-h-0 flex-1 flex-col p-0"><KitsTab /></TabsContent>
      </Tabs>
    </div>
  )
}
