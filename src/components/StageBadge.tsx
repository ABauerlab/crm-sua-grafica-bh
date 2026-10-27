import { Badge } from '@/components/ui/badge'
import { stageInfo } from '@/lib/format'
import type { Stage } from '@/lib/types'
import { cn } from '@/lib/utils'

export function StageBadge({ stage, className }: { stage: Stage; className?: string }) {
  const s = stageInfo(stage)
  return <Badge className={cn(s.color, className)}>{s.label}</Badge>
}
