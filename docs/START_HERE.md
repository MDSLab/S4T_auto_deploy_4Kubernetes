# 🚀 START HERE - One-Command Deployment

## ⚡ TL;DR - Comanda subito così:

```bash
cd s4t_crossplane_deployment
./setup-all.sh
```

**Aspetta 5-15 minuti e Stack4Things è pronto!**

---

## 📋 Cosa Fa?

Lo script `setup-all.sh` automatizza **tutto**:

- ✅ Installa k3s (Kubernetes)
- ✅ Installa Helm
- ✅ Genera certificati TLS
- ✅ Crea ConfigMaps
- ✅ Deploy Stack4Things completo
- ✅ Configura Keycloak e Keystone
- ✅ Deploy Crossplane
- ✅ Verifica tutto
- ✅ Mostra URL di accesso

---

## 🌐 Dopo il Deploy

Una volta completato:

**URL Dashboard**: `http://<IP-mostrato>/horizon`
**Username**: `admin`
**Password**: `s4t`

---

## 🔍 Verificare lo Stato

```bash
./verify-deployment.sh
```

Mostra status di tutti i componenti e URL di accesso.

---

## 🎯 Opzioni (se necessario)

```bash
# Se hai k3s già installato
./setup-all.sh --skip-k3s

# Se hai Helm già installato
./setup-all.sh --skip-helm

# Se hai entrambi
./setup-all.sh --skip-k3s --skip-helm

# Oppure usa Make
make setup              # Setup completo
make status             # Mostra stato
make clean              # Rimuovi deployment
```

---

## 📚 Documentazione

| File | Descrizione |
|------|-------------|
| [QUICKSTART.md](./QUICKSTART.md) | Guida rapida + troubleshooting |
| [DEPLOYMENT_SETUP.md](./DEPLOYMENT_SETUP.md) | Come funziona internamente |
| [README.md](./README.md) | Documentazione principale |
| [HOW_TO_USE.txt](./HOW_TO_USE.txt) | Guida di utilizzo |

---

## 🆘 Se Qualcosa Va Male

1. **Leggi l'output dello script** - Ha messaggi di errore chiari
2. **Esegui**: `./verify-deployment.sh` - Diagnostica stato
3. **Leggi**: [QUICKSTART.md - Troubleshooting](./QUICKSTART.md#troubleshooting)
4. **Check logs**: `kubectl logs -f -n default <pod-name>`

---

## ⏱️ Tempi

- **Prima volta**: 5-15 minuti (include k3s + container pulls)
- **Setup successivi**: 3-8 minuti (con `--skip-k3s --skip-helm`)

---

## ✨ Caratteristiche

- 🎯 Un singolo comando
- 🤖 Completamente automatizzato
- 🔄 Idempotente (safe to run multiple times)
- 🛡️ Robusto error handling
- 📊 Diagnostica integrata
- 📚 Documentazione completa

---

## 🚦 Quick Start Checklist

- [ ] Clone repo
- [ ] `cd s4t_crossplane_deployment`
- [ ] `./setup-all.sh`
- [ ] Aspetta 5-15 minuti
- [ ] `./verify-deployment.sh`
- [ ] Apri URL in browser
- [ ] Login con admin/s4t
- [ ] ✅ Fatto!

---

**Non aspettare, inizia subito:** `./setup-all.sh` 🎉
