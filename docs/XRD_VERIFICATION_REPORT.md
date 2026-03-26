# XRD Verification Report - provider-s4t
**Data:** 2026-03-26  
**Status:** ✅ ALL OK

## 1. Provider Installation
| Metrica | Valore |
|---------|--------|
| Pod Status | `2/2 Running` |
| Provider Installed | `True` |
| Provider Healthy | `True` |
| Package | `docker.io/mariorossi851234/provider-s4t:latest` |
| Runtime Config | `provider-s4t-runtime` (con sidecar proxy `alpine/socat:1.8.0.0`) |

## 2. CRD Registrati
- **Totale CRD:** 14 registrati nel cluster da `provider-s4t`
- **Tipologie principali:**
  - `devices.iot.s4t.crossplane.io`
  - `plugins.iot.s4t.crossplane.io`
  - `fleets.iot.s4t.crossplane.io`
  - `boardserviceinjections.iot.s4t.crossplane.io`
  - `ports.iot.s4t.crossplane.io`
  - `services.iot.s4t.crossplane.io`
  - `webservices.iot.s4t.crossplane.io`
  - `storeconfigs.s4t.crossplane.io`
  - E altri...

## 3. Risorse Istanziate e Funzionanti
| Tipo | Quantità | Status |
|------|----------|--------|
| Device | 1 | ✅ Ready=True, Synced=True |
| Plugin | 3 | ✅ Ready=True, Synced=True |
| Fleet | 0 | - |
| Site | 0 | - |

### Dettagli risorse principali:
- **Device `test-board-1`**
  - READY: `True`
  - SYNCED: `True`
  - Provider Config: `s4t-provider-domain`
  - Creato: 2026-03-25 15:27:37

- **Plugin `simple-logger`**
  - READY: `True`
  - SYNCED: `True`
  - Creato: 2026-03-26 07:40:22

- **Plugin `xrd-test-plugin`** (test creazione end-to-end)
  - READY: `True`
  - SYNCED: `True`
  - ✅ Creato e sincronizzato con successo

## 4. ProviderConfig
- **Nome:** `s4t-provider-domain`
- **Keystone Endpoint:** `http://keystone.default.svc.cluster.local:5000/v3`
- **Credenziali:** Secret `s4t-credentials` (default namespace)
- **Utenti attivi:** 3
- **Status:** ✅ Funzionante

## 5. Conclusioni
✅ **Provider completamente funzionante**
✅ **XRD correttamente registrate e disponibili per istanziazione**
✅ **Riconciliazione e sincronizzazione funzionano end-to-end**
✅ **Backend s4t/Iotronic connesso e raggiungibile**

## 6. Fix applicati
1. Immagine provider aggiornata da `docker.io/build-82783525/provider-s4t-amd64:latest` (403 Unauthorized)
   - ➜ `docker.io/mariorossi851234/provider-s4t:latest` ✅
2. RuntimeConfig sidecar `local-s4t-proxy` stabilizzata
   - ✗ Alpine con apk install runtime (CrashLoopBackOff Exit Code 127)
   - ➜ `alpine/socat:1.8.0.0` con socat pre-installato ✅
3. RuntimeConfig appena creata estratta e salvata in repo per persistenza

---
**Fine Report | All tests passed**
