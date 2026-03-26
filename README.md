# Unified Deploy: Stack4Things + Crossplane

Questa cartella raccoglie in un unico punto tutto il necessario per il deploy di S4T e Crossplane.

## Struttura

- `crossplane-provider/`: provider, package e risorse Crossplane
- `stack4things-improved/`: deploy S4T attivo
- `ops/`: script operativi (setup, verifica, utility)
- `docs/`: documentazione principale consolidata
- `scripts/`: script di migrazione/sync
- `archive/`: materiale legacy opzionale

## Migrazione

Esegui:

```bash
bash scripts/sync-from-root.sh
```

Lo script copia/aggiorna i contenuti dalla root del repository nella struttura unificata.

## Nota di sicurezza

La migrazione e' non distruttiva: non cancella i file sorgenti dalla root.
