import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { BrowserRouter } from 'react-router-dom'
import App from './App'
import { AuthProvider } from './auth/AuthProvider'
import { ErrorBoundary, recarregarUmaVez } from './components/ErrorBoundary'
import { ToastProvider } from './components/ui/toast'
import './index.css'
import { registrarServiceWorker } from './lib/push'

registrarServiceWorker()

// arquivo de tela que sumiu depois de uma publicação (aba antiga): recarrega sozinho em vez de tela branca
window.addEventListener('vite:preloadError', (e) => { e.preventDefault(); recarregarUmaVez() })

const queryClient = new QueryClient({
  defaultOptions: { queries: { staleTime: 10_000, refetchOnWindowFocus: true, retry: 1 } },
})

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <ErrorBoundary>
    <QueryClientProvider client={queryClient}>
      <BrowserRouter>
        <AuthProvider>
          <ToastProvider>
            <App />
          </ToastProvider>
        </AuthProvider>
      </BrowserRouter>
    </QueryClientProvider>
    </ErrorBoundary>
  </StrictMode>,
)
