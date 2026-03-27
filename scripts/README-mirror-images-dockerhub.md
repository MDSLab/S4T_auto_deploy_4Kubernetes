# Mirror Images to Docker Hub

Guida per usare lo script `scripts/mirror-images-dockerhub.sh`, che copia immagini container esistenti verso un nuovo namespace Docker Hub senza rebuild.

## Cosa fa

- Estrae immagini dal repository (`image:` nei manifest + `FROM` nei Dockerfile) con `--from-repo`.
- Può anche leggere una lista immagini esterna con `--images-file`.
- Deduplica l'inventory e la salva in un file (`images.txt` di default).
- Esegue mirror su Docker Hub con `skopeo copy --all` (supporto multi-arch).
- Supporta modalità di anteprima con `--dry-run`.

## Prerequisiti

- Linux con bash.
- Docker installato e daemon attivo.
- `skopeo`, `grep`, `sed`, `sort` disponibili.
- Login al nuovo account Docker Hub.

Installazione rapida prerequisiti (Ubuntu):

```bash
sudo apt-get update
sudo apt-get install -y docker.io skopeo
sudo systemctl enable --now docker
```

Login Docker Hub:

```bash
docker login -u <DOCKERHUB_USER>
```

## Uso rapido

Dalla root del repository:

```bash
cd /home/ubuntu/unified-deploy
chmod +x ./scripts/mirror-images-dockerhub.sh
```

1) Anteprima (nessun push):

```bash
./scripts/mirror-images-dockerhub.sh --user <DOCKERHUB_USER> --from-repo --dry-run
```

2) Esecuzione reale (push):

```bash
./scripts/mirror-images-dockerhub.sh --user <DOCKERHUB_USER> --from-repo
```

## Opzioni

```text
--user <name>            Namespace Docker Hub di destinazione (obbligatorio)
--images-file <path>     File con elenco immagini (una per riga)
--from-repo              Estrae immagini da manifest/Dockerfile/compose del repository
--output-file <path>     Dove salvare l'inventory (default: ./images.txt)
--only-users <u1,u2>     Filtra immagini sorgente per namespace utente (CSV)
--dry-run                Mostra le azioni senza copiare/pushare
-h, --help               Mostra aiuto
```

Nota su `--only-users`:

- Con `--from-repo --only-users ...` lo script esegue anche una scansione ampia dei file del progetto.
- In questo modo intercetta riferimenti container nei namespace indicati anche fuori dai soli campi `image:` e `FROM`.
- Esempi tipici inclusi: campi `package`, `newName` e variabili in script di deploy.

## Esempi

Solo repository:

```bash
./scripts/mirror-images-dockerhub.sh --user mydockeruser --from-repo
```

Solo namespace sorgente specifici (es. `lucadagati` e `mariorossi851234`):

```bash
./scripts/mirror-images-dockerhub.sh \
  --user mydockeruser \
  --from-repo \
  --only-users lucadagati,mariorossi851234
```

Repository + file immagini custom:

```bash
./scripts/mirror-images-dockerhub.sh \
  --user mydockeruser \
  --from-repo \
  --images-file ./extra-images.txt \
  --output-file ./images-merged.txt
```

Solo file immagini custom:

```bash
./scripts/mirror-images-dockerhub.sh --user mydockeruser --images-file ./images.txt
```

## Formato file immagini

Una immagine per riga. Sono accettati:

- `repo/image:tag`
- `registry.example.com/repo/image:tag`
- `repo/image@sha256:<digest>`

Esempio:

```text
nginx:1.27
quay.io/keycloak/keycloak:24.0.4
docker.io/library/postgres:15
my-registry.local/team/app@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
```

## Come viene costruito il nome destinazione

Lo script converte ogni immagine sorgente in un repository Docker Hub sicuro sotto `<DOCKERHUB_USER>`.

Esempio logico:

- sorgente: `quay.io/keycloak/keycloak:24.0.4`
- destinazione: `docker.io/<DOCKERHUB_USER>/keycloak-keycloak:24.0.4`

Nota:

- eventuale prefisso registry (`quay.io`, `docker.io`, `gcr.io`, ecc.) viene rimosso dal nome base;
- i separatori (`/`, `:`, `@`) vengono convertiti in `-` per evitare collisioni e caratteri invalidi.

## Comportamento con immagini locali vs remote

Per ogni immagine:

- se presente localmente (`docker image inspect`), usa `docker-daemon:<image>` come sorgente;
- altrimenti usa `docker://<image>` e la scarica dal registry sorgente.

## Errori comuni

`Comando mancante: skopeo`
- Installa `skopeo`.

`unauthorized` / `denied`
- Esegui login su Docker Hub (`docker login -u <DOCKERHUB_USER>`).
- Se l'immagine sorgente è privata, fai login anche al registry sorgente.

`manifest unknown` / `not found`
- L'immagine o il tag non esistono nel registry sorgente.
- Verifica la riga nell'inventory generato.

## Verifica post-mirror

Controlla che il file inventory sia stato creato e conta le immagini:

```bash
wc -l ./images.txt
```

Verifica alcuni repository pushati su Docker Hub:

```bash
docker search <DOCKERHUB_USER>
```

## Note operative

- Esegui sempre prima con `--dry-run`.
- In caso di infrastrutture grandi, conserva l'output su file:

```bash
./scripts/mirror-images-dockerhub.sh --user <DOCKERHUB_USER> --from-repo | tee ./mirror.log
```

- Per includere solo immagini di namespace specifici:

```bash
./scripts/mirror-images-dockerhub.sh \
  --user <DOCKERHUB_USER> \
  --from-repo \
  --only-users lucadagati,mariorossi851234 \
  --dry-run
```

- Lo script non modifica i manifest: copia solo le immagini.
